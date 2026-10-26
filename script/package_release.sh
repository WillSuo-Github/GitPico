#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: script/package_release.sh
Required environment:
  GITPICO_SIGNING_IDENTITY       Developer ID Application identity
  GITPICO_TEAM_ID                Apple Developer team identifier
  GITPICO_NOTARY_PROFILE         Existing notarytool Keychain profile
  GITPICO_UPDATE_FEED_URL        Optional HTTPS appcast URL (defaults to GitHub Releases)
  GITPICO_UPDATE_PUBLIC_KEY      Base64 Ed25519 update verification key
  GITPICO_UPDATE_DOWNLOAD_PREFIX Optional HTTPS download directory (defaults to this build's GitHub Release)
Optional:
  GITPICO_SPARKLE_BIN            Sparkle tools directory
  GITPICO_SPARKLE_ACCOUNT        Keychain Ed25519 account (default com.willsuo.GitPico.updates)
Builds a universal app, notarizes/staples it and prepares a signed appcast.
Does not upload, publish or alter the development marketing version.
HELP
  exit 0
fi

: "${GITPICO_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
: "${GITPICO_TEAM_ID:?Set the Apple Developer team identifier}"
: "${GITPICO_NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
: "${GITPICO_UPDATE_PUBLIC_KEY:?Set the public Ed25519 verification key}"
GITPICO_UPDATE_FEED_URL="${GITPICO_UPDATE_FEED_URL:-https://github.com/WillSuo-Github/GitPico/releases/latest/download/appcast.xml}"
export GITPICO_UPDATE_FEED_URL
[[ "$GITPICO_SIGNING_IDENTITY" == "Developer ID Application:"* ]] || { echo 'A Developer ID Application signing identity is required.' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit reviewed source changes before packaging a release.' >&2; exit 1; }
python3 - <<'PY'
import base64, os
from urllib.parse import urlsplit
for name in ('GITPICO_UPDATE_FEED_URL', 'GITPICO_UPDATE_DOWNLOAD_PREFIX'):
    if not os.environ.get(name): continue
    value = urlsplit(os.environ[name])
    if value.scheme != 'https' or not value.hostname or value.username or value.password or value.fragment or value.query:
        raise SystemExit(name + ' must use HTTPS without credentials, queries or fragments.')
if len(base64.b64decode(os.environ['GITPICO_UPDATE_PUBLIC_KEY'], validate=True)) != 32:
    raise SystemExit('The update public key must decode to 32 bytes.')
PY

ARCHIVE_DIR="$ROOT_DIR/.build/distribution/$(TZ=Asia/Shanghai date +%Y%m%d%H%M%S)"
mkdir -p "$ARCHIVE_DIR"
xcodebuild archive -project GitPico.xcodeproj -scheme GitPico -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE_DIR/GitPico.xcarchive" \
  -derivedDataPath "$ROOT_DIR/.build/distribution-derived" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$GITPICO_SIGNING_IDENTITY" DEVELOPMENT_TEAM="$GITPICO_TEAM_ID" \
  GITPICO_UPDATE_FEED_URL="$GITPICO_UPDATE_FEED_URL" GITPICO_UPDATE_PUBLIC_KEY="$GITPICO_UPDATE_PUBLIC_KEY" \
  > "$ARCHIVE_DIR/archive.log" 2>&1
APP="$ARCHIVE_DIR/GitPico.xcarchive/Products/Applications/GitPico.app"
BUILD_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
OUTPUT_DIR="$ROOT_DIR/dist/releases/$BUILD_ID"
GITPICO_UPDATE_DOWNLOAD_PREFIX="${GITPICO_UPDATE_DOWNLOAD_PREFIX:-https://github.com/WillSuo-Github/GitPico/releases/download/build-$BUILD_ID}"
mkdir -p "$OUTPUT_DIR"
codesign --verify --deep --strict "$APP"
lipo -verify_arch arm64 x86_64 "$APP/Contents/MacOS/GitPico"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE_DIR/notarization.zip"
xcrun notarytool submit "$ARCHIVE_DIR/notarization.zip" --keychain-profile "$GITPICO_NOTARY_PROFILE" --wait --output-format json > "$OUTPUT_DIR/notarization.json"
python3 - "$OUTPUT_DIR/notarization.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
if record.get('status') != 'Accepted':
    raise SystemExit('Notarization did not report Accepted. Inspect the retained report before proceeding.')
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/GitPico-$BUILD_ID.zip"
SPARKLE_BIN="${GITPICO_SPARKLE_BIN:-$ROOT_DIR/.build/distribution-derived/SourcePackages/artifacts/sparkle/Sparkle/bin}"
"$SPARKLE_BIN/generate_appcast" --account "${GITPICO_SPARKLE_ACCOUNT:-com.willsuo.GitPico.updates}" \
  --download-url-prefix "${GITPICO_UPDATE_DOWNLOAD_PREFIX%/}/" "$OUTPUT_DIR"
python3 "$ROOT_DIR/script/validate_appcast.py" "$OUTPUT_DIR/appcast.xml" "$BUILD_ID"
python3 - "$OUTPUT_DIR" "$BUILD_ID" "$(git rev-parse HEAD)" <<'PY'
import hashlib, json, sys
from pathlib import Path
folder, build, commit = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
archive = folder / ('GitPico-' + build + '.zip')
def hash_archive(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()
(folder / 'manifest.json').write_text(json.dumps({'build': build, 'commit': commit, 'sha256': hash_archive(archive)}, indent=2) + '\n')
PY
echo "Prepared signed, notarized release and appcast in $OUTPUT_DIR. Nothing was uploaded."
