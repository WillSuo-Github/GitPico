#!/usr/bin/env python3
"""Write Xcode's derived Info.plist without changing source or project settings."""
import os
import plistlib
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from build_number import build_number


def generate_metadata(environment):
    source = Path(environment['SRCROOT'])
    derived = Path(environment['DERIVED_FILE_DIR']) / 'GitPico-Info.plist'
    values = plistlib.loads((source / 'Configuration/GitPico-Info.plist').read_bytes())
    previous = []
    candidates = [derived, source / 'dist/GitPico.app/Contents/Info.plist']
    if environment.get('TARGET_BUILD_DIR') and environment.get('INFOPLIST_PATH'):
        candidates.append(Path(environment['TARGET_BUILD_DIR']) / environment['INFOPLIST_PATH'])
    for candidate in candidates:
        try:
            value = str(plistlib.loads(candidate.read_bytes()).get('CFBundleVersion', ''))
            if len(value) == 14 and value.isdecimal():
                previous.append(value)
        except (OSError, plistlib.InvalidFileException):
            pass
    values['CFBundleVersion'] = build_number(datetime.now(ZoneInfo('Asia/Shanghai')), max(previous, default=''))
    derived.parent.mkdir(parents=True, exist_ok=True)
    temporary = derived.with_suffix('.plist.tmp')
    temporary.write_bytes(plistlib.dumps(values))
    temporary.replace(derived)
    print('GitPico development build: ' + values['CFBundleVersion'])
    return values['CFBundleVersion']


if __name__ == '__main__':
    generate_metadata(os.environ)
