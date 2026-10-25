#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen 2.46+ is needed only to regenerate the project; the checked-in GitPico.xcodeproj opens without it." >&2
    exit 1
fi
xcodegen generate --spec "$ROOT_DIR/project.yml"
