#!/usr/bin/env python3
"""Reject incomplete update feeds before publication."""
import base64
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit


def validate(path, build):
    sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
    root = ET.parse(path).getroot()
    for item in root.findall('.//item'):
        enclosure = item.find('enclosure')
        if enclosure is None:
            continue
        version = enclosure.get('{' + sparkle + '}version') or item.findtext('{' + sparkle + '}version')
        if version != build:
            continue
        address = urlsplit(enclosure.get('url', ''))
        if address.scheme != 'https' or not address.hostname or address.username or address.password:
            raise ValueError('Update enclosure must use HTTPS without embedded credentials.')
        signature = enclosure.get('{' + sparkle + '}edSignature', '')
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError('Missing or invalid Ed25519 update signature.')
        if int(enclosure.get('length', '0')) <= 0:
            raise ValueError('Missing archive length.')
        return
    raise ValueError('No signed enclosure matches the staged build.')


if __name__ == '__main__':
    validate(sys.argv[1], sys.argv[2])
