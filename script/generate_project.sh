#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen 2.46+ is needed only to regenerate the project; the checked-in GitPico.xcodeproj opens without it." >&2
    exit 1
fi
xcodegen generate --spec "$ROOT_DIR/project.yml"
# Synchronized source groups hide catalog contents from XcodeGen's region scan.
# Register the same declared languages deterministically after project generation.
python3 - "$ROOT_DIR" <<'PY'
import json
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
manifest = json.loads((root / 'Configuration/Localizations.json').read_text())
regions = ['Base', manifest['sourceLanguage']] + manifest['localizations']
block = 'knownRegions = (\n' + ''.join('\t\t\t\t' + json.dumps(region) + ',\n' for region in regions) + '\t\t\t);'
path = root / 'GitPico.xcodeproj/project.pbxproj'
text, count = re.subn(r'knownRegions = \([^)]*\);', lambda _: block, path.read_text())
assert count == 1, 'Expected one generated project region list.'
path.write_text(text)
PY
