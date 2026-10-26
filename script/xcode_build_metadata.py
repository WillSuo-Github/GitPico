#!/usr/bin/env python3
"""Write Xcode's derived Info.plist without changing source or project settings."""
import os
import base64
import plistlib
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
from urllib.parse import urlsplit

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
    feed = environment.get('GITPICO_UPDATE_FEED_URL', '').strip()
    key = environment.get('GITPICO_UPDATE_PUBLIC_KEY', '').strip()
    if key and not feed and values.get('GitPicoUpdateRepository'):
        feed = 'https://github.com/' + values['GitPicoUpdateRepository'] + '/releases/latest/download/appcast.xml'
    if feed or key:
        address = urlsplit(feed)
        if address.scheme != 'https' or not address.hostname or address.username or address.password or address.fragment:
            raise ValueError('Update feed must be an HTTPS URL without embedded credentials or fragment.')
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError('Update verification key must be a base64 Ed25519 public key.')
        values.update(SUFeedURL=feed, SUPublicEDKey=key, SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True, SUShowReleaseNotes=False)
    derived.parent.mkdir(parents=True, exist_ok=True)
    temporary = derived.with_suffix('.plist.tmp')
    temporary.write_bytes(plistlib.dumps(values))
    temporary.replace(derived)
    print('GitPico development build: ' + values['CFBundleVersion'])
    return values['CFBundleVersion']


if __name__ == '__main__':
    generate_metadata(os.environ)
