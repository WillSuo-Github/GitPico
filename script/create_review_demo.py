#!/usr/bin/env python3
"""Create isolated repositories for line staging and conflict UI checks."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
(root / 'dist').mkdir(exist_ok=True)
parent = Path(tempfile.mkdtemp(prefix='ReviewDemo-', dir=root / 'dist'))


def git(path, *arguments, allowed=(0,)):
    result = subprocess.run(['git', '-C', str(path), *arguments], capture_output=True, text=True)
    if result.returncode not in allowed:
        raise RuntimeError(result.stderr)
    return result


def repository(name):
    path = parent / name
    path.mkdir()
    git(path, 'init', '-b', 'main')
    git(path, 'config', 'user.name', 'Pico Team')
    git(path, 'config', 'user.email', 'hello@example.invalid')
    git(path, 'config', 'commit.gpgsign', 'false')
    return path


lines = repository('LineReview')
original = '\n'.join(['# Native review', '', 'let title = "Original"', 'let subtitle = "Keep this change separate"', 'let enabled = false', ''] + [f'// Context line {n}' for n in range(1, 40)]) + '\n'
(lines / 'Review.swift').write_text(original)
git(lines, 'add', '--all')
git(lines, 'commit', '-m', 'Prepare a focused review')
(lines / 'Review.swift').write_text(original.replace('"Original"', '"GitPico"').replace('enabled = false', 'enabled = true'))

conflicts = repository('ConflictReview')
git(conflicts, 'config', 'merge.conflictstyle', 'diff3')
(conflicts / 'Welcome.swift').write_text('import Foundation\n\nstruct Welcome {\n    let title = "Hello"\n    let subtitle = "Start here"\n}\n')
git(conflicts, 'add', '--all')
git(conflicts, 'commit', '-m', 'Add the welcome screen')
git(conflicts, 'switch', '-c', 'feature/welcome')
(conflicts / 'Welcome.swift').write_text('import Foundation\n\nstruct Welcome {\n    let title = "Welcome back"\n    let subtitle = "Your branches are ready"\n}\n')
git(conflicts, 'commit', '-am', 'Refresh welcome copy')
git(conflicts, 'switch', 'main')
(conflicts / 'Welcome.swift').write_text('import Foundation\n\nstruct Welcome {\n    let title = "GitPico"\n    let subtitle = "A quieter Git workflow"\n}\n')
git(conflicts, 'commit', '-am', 'Use product copy')
git(conflicts, 'merge', '--no-edit', 'feature/welcome', allowed=(1,))
print(json.dumps({'parent': str(parent), 'lines': str(lines), 'conflicts': str(conflicts)}))
