#!/usr/bin/env python3
"""Select one exact private release draft from paginated GitHub responses."""
import json
import sys


def select(pages, tag):
    if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
        raise ValueError('Expected paginated release arrays.')
    matches = [release for page in pages for release in page
               if isinstance(release, dict) and release.get('tag_name') == tag]
    if len(matches) != 1 or matches[0].get('draft') is not True:
        raise ValueError('Expected exactly one matching draft release.')
    return matches[0]


if __name__ == '__main__':
    with open(sys.argv[1]) as stream:
        release = select(json.load(stream), sys.argv[2])
    with open(sys.argv[3], 'w') as stream:
        json.dump(release, stream, indent=2)
        stream.write('\n')
