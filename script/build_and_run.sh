#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="GitPico"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
cd "$ROOT_DIR"

case "$MODE" in
  run|--verify|--background|--debug|--logs|--telemetry|--demo|--build-only) ;;
  *) echo "usage: $0 [run|--verify|--background|--debug|--logs|--telemetry|--demo|--build-only]" >&2; exit 2 ;;
esac

case "$MODE" in
  run|--demo|--debug) pkill -x "$APP_NAME" >/dev/null 2>&1 || true ;;
esac
if [[ ! -f "$ROOT_DIR/GitPico.xcodeproj/project.pbxproj" ]]; then "$ROOT_DIR/script/generate_project.sh"; fi
xcodebuild -project "$ROOT_DIR/GitPico.xcodeproj" -scheme "$APP_NAME" \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$ROOT_DIR/.build/xcode" build
BUILD_APP="$ROOT_DIR/.build/xcode/Build/Products/Debug/$APP_NAME.app"
mkdir -p "$ROOT_DIR/dist"
# dist/GitPico.app is generated output; replace the whole bundle to avoid stale resources.
rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$BUILD_APP" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

case "$MODE" in
  --build-only) echo "Built $APP_BUNDLE" ;;
  --demo)
    "$ROOT_DIR/script/create_demo.sh"
    /usr/bin/open -n "$APP_BUNDLE" --args --repository "$ROOT_DIR/dist/PicoDemo"
    ;;
  --debug) lldb -- "$APP_MACOS/$APP_NAME" ;;
  --logs|--telemetry)
    /usr/bin/open -g -j -n "$APP_BUNDLE" --args --background-testing
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|--background)
    VERIFY_OUTPUT="$ROOT_DIR/dist/background-verification.json"
    rm -f "$VERIFY_OUTPUT"
    VERIFY_ARGS=(--background-testing --verification-output "$VERIFY_OUTPUT")
    if [[ "$MODE" == "--verify" ]]; then VERIFY_ARGS+=(--verification-exit); fi
    /usr/bin/open -g -j -n "$APP_BUNDLE" --args "${VERIFY_ARGS[@]}"
    python3 - "$VERIFY_OUTPUT" <<'PYVERIFY'
import json, sys, time
from pathlib import Path
path = Path(sys.argv[1])
deadline = time.monotonic() + 15
while not path.exists() and time.monotonic() < deadline:
    time.sleep(0.1)
assert path.exists(), 'The background application did not produce its verification report.'
result = json.loads(path.read_text())
assert result['backgroundTesting'] and not result['isActive'] and result['visibleWindows'] == 0, result
assert result['frontmostProcessIdentifier'] != result['processIdentifier'], result
print(json.dumps(result, indent=2))
PYVERIFY
    ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
