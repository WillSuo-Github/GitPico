#!/usr/bin/env python3
"""Create isolated repositories for automatic-stash, line and drag review."""
import json
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
base = Path(tempfile.mkdtemp(prefix='InteractionReview-', dir=root / 'dist'))

def git(repo, *args):
    return subprocess.check_output(['/usr/bin/git', '-C', str(repo), *args], text=True).strip()

for name in ['TowerReference', 'Client']:
    repo = base / name
    repo.mkdir()
    git(repo, 'init', '-b', 'main')
    for key, value in [('user.name', 'Pico Team'), ('user.email', 'hello@example.invalid'), ('commit.gpgsign', 'false'), ('core.hooksPath', '/dev/null')]:
        git(repo, 'config', key, value)
    (repo / 'Layout.swift').write_text('let spacing = 12\nlet radius = 8\nlet title = "Welcome"\n')
    (repo / 'Notes.txt').write_text('Base notes.\n')
    git(repo, 'add', '.')
    git(repo, 'commit', '-m', 'Start interaction review')
    git(repo, 'switch', '-c', 'feature/sidebar')
    (repo / 'Feature.txt').write_text('Sidebar feature.\n')
    git(repo, 'add', '.')
    git(repo, 'commit', '-m', 'Add sidebar feature')
    git(repo, 'switch', 'main')
    (repo / 'Layout.swift').write_text('let spacing = 14\nlet radius = 8\nlet title = "Hello"\n')
    git(repo, 'add', 'Layout.swift')
    (repo / 'Notes.txt').write_text('Draft notes.\n')
    (repo / 'Draft.txt').write_text('Untracked idea.\n')
    git(repo, 'stash', 'push', '-u', '-m', 'Line and drag review')
    (repo / 'Notes.txt').write_text('Automatic stash local draft.\n')
    git(repo, 'add', 'Notes.txt')
    (repo / 'Draft.txt').write_text('Keep this untracked draft.\n')
info = {name: str(base / name) for name in ['TowerReference', 'Client']}
(base / 'review.json').write_text(json.dumps(info, indent=2)+'\n')
print(json.dumps(info, indent=2))
