#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || $# -ne 1 ]]; then
  echo 'Usage: script/publish_github_release.sh dist/releases/<build>'
  echo 'Creates/resumes a PRIVATE GitHub draft release, binds appcast URLs to its asset IDs and re-signs the feed.'
  echo 'Required: a clean committed checkout, gh access, the matching Sparkle Keychain key and a notarized package.'
  echo 'Does not publish the draft. Review it in GitHub before making it the latest release.'
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit reviewed source changes before preparing a release.' >&2; exit 1; }
OUTPUT_DIR="$(cd "$1" && pwd)"
BUILD_ID="$(basename "$OUTPUT_DIR")"
[[ "$BUILD_ID" =~ ^[0-9]{14}$ ]] || { echo 'Expected a date build directory.' >&2; exit 1; }
REPOSITORY='WillSuo-Github/GitPico'
[[ "$(gh api "repos/$REPOSITORY" --jq .private)" == true ]] || { echo 'The configured GitPico repository must remain private.' >&2; exit 1; }
TAG="build-$BUILD_ID"
ZIP_NAME="GitPico-$BUILD_ID.zip"
[[ -f "$OUTPUT_DIR/$ZIP_NAME" && -f "$OUTPUT_DIR/appcast.xml" && -f "$OUTPUT_DIR/notarization.json" && -f "$OUTPUT_DIR/manifest.json" ]] || { echo 'Prepare the notarized package and source manifest first.' >&2; exit 1; }
python3 - "$OUTPUT_DIR" "$BUILD_ID" "$(git rev-parse HEAD)" <<'PY'
import hashlib, json, sys
from pathlib import Path
folder, build, commit = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
record = json.loads((folder / 'manifest.json').read_text())
archive = folder / ('GitPico-' + build + '.zip')
def hash_archive(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()
if record.get('build') != build or record.get('commit') != commit or record.get('sha256') != hash_archive(archive):
    raise SystemExit('The package does not match this committed source or its recorded archive hash.')
PY
python3 - "$OUTPUT_DIR/notarization.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted': raise SystemExit('Notarization must be Accepted.')
PY
if gh release view "$TAG" --repo "$REPOSITORY" --json isDraft > "$OUTPUT_DIR/draft-status.json" 2>/dev/null; then
  [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["isDraft"])' "$OUTPUT_DIR/draft-status.json")" == True ]] || { echo 'This release is already published. Generate a new build instead.' >&2; exit 1; }
else
  gh release create "$TAG" --repo "$REPOSITORY" --target "$(git rev-parse HEAD)" --draft \
    --title "GitPico 0.01 ($BUILD_ID)" --notes "Development build $BUILD_ID. Review validation, signing and update results before publication."
fi
mkdir -p "$OUTPUT_DIR/remote-check"
if ! gh release download "$TAG" --repo "$REPOSITORY" --pattern "$ZIP_NAME" --dir "$OUTPUT_DIR/remote-check" --clobber >/dev/null 2>&1; then
  gh release upload "$TAG" "$OUTPUT_DIR/$ZIP_NAME" --repo "$REPOSITORY"
else
  cmp -s "$OUTPUT_DIR/$ZIP_NAME" "$OUTPUT_DIR/remote-check/$ZIP_NAME" || { echo 'Existing remote archive differs. Use a new build.' >&2; exit 1; }
fi
# The tag endpoint can return 404 for an authenticated private draft even when
# release creation/upload succeeded. The releases list includes owned drafts.
gh api --paginate --slurp "repos/$REPOSITORY/releases?per_page=100" > "$OUTPUT_DIR/github-releases.json"
python3 "$ROOT_DIR/script/select_github_draft.py" "$OUTPUT_DIR/github-releases.json" "$TAG" "$OUTPUT_DIR/github-release.json"
ASSET_ID="$(python3 - "$OUTPUT_DIR/github-release.json" "$ZIP_NAME" <<'PY'
import json,sys
values=[a['id'] for a in json.load(open(sys.argv[1]))['assets'] if a['name']==sys.argv[2]]
if len(values)!=1: raise SystemExit('Expected exactly one uploaded archive asset.')
print(values[0])
PY
)"
python3 "$ROOT_DIR/script/prepare_github_appcast.py" "$OUTPUT_DIR/appcast.xml" "$BUILD_ID" "$REPOSITORY" "$ASSET_ID"
SPARKLE_BIN="${GITPICO_SPARKLE_BIN:-$ROOT_DIR/.build/distribution-derived/SourcePackages/artifacts/sparkle/Sparkle/bin}"
"$SPARKLE_BIN/generate_appcast" --account "${GITPICO_SPARKLE_ACCOUNT:-com.willsuo.GitPico.updates}" "$OUTPUT_DIR"
python3 "$ROOT_DIR/script/validate_appcast.py" "$OUTPUT_DIR/appcast.xml" "$BUILD_ID"
python3 - "$OUTPUT_DIR/appcast.xml" "$REPOSITORY" "$ASSET_ID" <<'PY'
import sys,xml.etree.ElementTree as E
expected='https://api.github.com/repos/'+sys.argv[2]+'/releases/assets/'+sys.argv[3]
if not any(e.get('url')==expected for e in E.parse(sys.argv[1]).findall('.//enclosure')):
    raise SystemExit('Appcast generation changed the private asset URL; inspect before uploading.')
PY
gh release upload "$TAG" "$OUTPUT_DIR/appcast.xml" --repo "$REPOSITORY" --clobber
echo "Prepared private GitHub draft release $TAG. Review before publishing; no draft was published."
