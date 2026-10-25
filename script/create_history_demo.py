#!/usr/bin/env python3
"""Create a fresh linear-history repository for native history-rewrite checks."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
(root / 'dist').mkdir(exist_ok=True)
path = Path(tempfile.mkdtemp(prefix='HistoryReview-', dir=root / 'dist'))

def git(*arguments):
    result = subprocess.run(['git', '-C', str(path), *arguments], capture_output=True, text=True, check=True)
    return result.stdout.strip()

git('init', '-b', 'main')
for key, value in [('user.name', 'Pico Team'), ('user.email', 'hello@example.invalid'), ('commit.gpgsign', 'false')]:
    git('config', key, value)
(path / 'README.md').write_text('# GitPico history review\n')
git('add', '--all')
git('commit', '-m', 'Prepare a quiet history review')
git('tag', 'review-base')
for filename, content, message in [('Welcome.swift', 'let title = "GitPico"\n', 'Add welcome copy'), ('Theme.swift', 'let accent = "purple"\n', 'Add theme'), ('Layout.swift', 'let sidebarWidth = 359\n', 'Tune sidebar spacing'), ('Notes.md', 'Keep each commit focused.\n', 'Document review tips')]:
    (path / filename).write_text(content)
    git('add', '--all')
    git('commit', '-m', message)
print(json.dumps({'path': str(path), 'base': git('rev-parse', 'review-base'), 'head': git('rev-parse', 'HEAD')}))
