#!/usr/bin/env python3
"""Normalize completed ASC CLI and notarytool receipts without discarding provider evidence."""
import json
import sys
from pathlib import Path


def normalize(value):
    if not isinstance(value, dict):
        raise ValueError('Notarization receipt must be an object.')
    if isinstance(value.get('data'), dict):
        item = value['data']
        status = item.get('attributes', {}).get('status')
        identifier = item.get('id')
    else:
        status, identifier = value.get('status'), value.get('id')
    if status != 'Accepted' or not isinstance(identifier, str) or not identifier:
        raise ValueError('Notarization did not report Accepted. Inspect the retained provider receipt.')
    return {'id': identifier, 'status': status}


if __name__ == '__main__':
    source, destination = map(Path, sys.argv[1:3])
    destination.write_text(json.dumps(normalize(json.loads(source.read_text())), indent=2) + '\n')
