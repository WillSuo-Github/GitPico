#!/usr/bin/env python3
"""Bind an appcast to the exact uploaded GitHub archive asset."""
import sys
import xml.etree.ElementTree as ET


def prepare(file, build, project, asset_id, access='api'):
    parts = project.split('/')
    if len(parts) != 2 or not all(part and part not in ('.', '..') and all(c.isascii() and (c.isalnum() or c in '-_.') for c in part) for part in parts) or not str(asset_id).isdigit() or int(asset_id) <= 0:
        raise ValueError('Invalid GitHub repository or release asset identifier.')
    if access not in ('api', 'public') or len(build) != 14 or not build.isascii() or not build.isdigit():
        raise ValueError('Invalid release access mode or date build number.')
    sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
    ET.register_namespace('sparkle', sparkle)
    tree = ET.parse(file)
    found = False
    for item in tree.getroot().findall('.//item'):
        enclosure = item.find('enclosure')
        if enclosure is None: continue
        version = enclosure.get('{' + sparkle + '}version') or item.findtext('{' + sparkle + '}version')
        if version == build:
            address = ('https://github.com/' + project + '/releases/download/build-' + build + '/GitPico-' + build + '.zip') if access == 'public' else ('https://api.github.com/repos/' + project + '/releases/assets/' + str(asset_id))
            enclosure.set('url', address)
            found = True
            for link in item.findall('{' + sparkle + '}releaseNotesLink'):
                item.remove(link)
    if not found: raise ValueError('No enclosure matches this build.')
    tree.write(file, encoding='utf-8', xml_declaration=True)


if __name__ == '__main__':
    prepare(*sys.argv[1:])
