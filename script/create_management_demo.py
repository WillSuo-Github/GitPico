#!/usr/bin/env python3
"""Create disposable local remotes, refs and stashes for native management review."""
import json
import pathlib
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parents[1]
(project / "dist").mkdir(exist_ok=True)
folder = pathlib.Path(tempfile.mkdtemp(prefix="ManagementReview-", dir=project / "dist"))
client = folder / "Client"
client.mkdir()


def git(*args, at=client):
    return subprocess.check_output(["/usr/bin/git", "-C", str(at), *args], text=True, stderr=subprocess.STDOUT).strip()


def write(path, text):
    target = client / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


git("init", "-b", "main")
for key, value in [("user.name", "Pico Team"), ("user.email", "hello@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")]:
    git("config", key, value)
write("README.md", "# Management Review\n\nNative repository management.\n")
write("Sources/Layout.swift", "let spacing = 12\nlet radius = 8\n")
git("add", "--all"); git("commit", "-m", "Prepare repository management")
git("tag", "v0.1"); git("branch", "feature/sidebar")
write("Notes.md", "Review branches, tags, remotes and stashes.\n")
git("add", "--all"); git("commit", "-m", "Document management review")
git("tag", "-a", "v0.2", "-m", "Management preview")
git("branch", "cleanup/merged")
for name in ["Origin.git", "Mirror.git"]:
    git("init", "--bare", "--initial-branch=main", str(folder / name))
git("remote", "add", "origin", str(folder / "Origin.git"))
git("push", "--set-upstream", "origin", "main", "feature/sidebar", "--tags")
write("Sources/Layout.swift", "let spacing = 14\nlet radius = 8\n")
git("add", "Sources/Layout.swift")
write("README.md", "# Management Review\n\nDraft welcome copy.\n")
write("Draft.txt", "An untracked idea.\n")
git("stash", "push", "--include-untracked", "-m", "Sidebar polish and welcome draft")
write("Notes.md", "Review every stash option before applying.\n")
git("stash", "push", "-m", "Review checklist")
report = dict(directory=str(folder), repository=str(client), remote=str(folder / "Origin.git"), mirror=str(folder / "Mirror.git"), head=git("rev-parse", "HEAD"))
(folder / "review.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
