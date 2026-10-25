#!/usr/bin/env python3
"""Generate a monotonic development build timestamp in Asia/Shanghai."""
import plistlib
import sys
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo


def build_number(now: datetime, previous: str = '') -> str:
    current = now.astimezone(ZoneInfo('Asia/Shanghai'))
    stamp = current.strftime('%Y%m%d%H%M%S')
    if len(previous) == 14 and previous.isdecimal() and previous >= stamp:
        try:
            prior = datetime.strptime(previous, '%Y%m%d%H%M%S')
            stamp = (prior + timedelta(seconds=1)).strftime('%Y%m%d%H%M%S')
        except ValueError:
            pass
    return stamp


if __name__ == '__main__':
    previous = ''
    if len(sys.argv) > 1:
        try:
            previous = str(plistlib.loads(Path(sys.argv[1]).read_bytes()).get('CFBundleVersion', ''))
        except (OSError, plistlib.InvalidFileException):
            pass
    print(build_number(datetime.now(ZoneInfo('Asia/Shanghai')), previous))
