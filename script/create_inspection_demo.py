#!/usr/bin/env python3
"""Create a fresh disposable repository for native file/history parity review."""
import json
import pathlib
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parents[1]
(project / "dist").mkdir(exist_ok=True)
repository = pathlib.Path(tempfile.mkdtemp(prefix="InspectionReview-", dir=project / "dist"))


def git(*arguments):
    return subprocess.check_output(["/usr/bin/git", "-C", str(repository), *arguments], text=True).strip()


def write(path, text):
    destination = repository / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)


def commit(message, author="Pico Team", email="hello@example.invalid"):
    git("add", "--all")
    git("-c", "user.name=" + author, "-c", "user.email=" + email, "commit", "-m", message)
    return git("rev-parse", "HEAD")


git("init", "-b", "main")
for key, value in [("user.name", "Pico Team"), ("user.email", "hello@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")]:
    git("config", key, value)
write("README.md", "# Inspection Review\n\nA disposable GitPico playground.\n")
base = commit("Prepare file inspection review")
git("tag", "review-base")
write("Sources/Welcome.swift", 'let title = "GitPico"\nlet spacing = 12\nlet showGraph = true\n')
added = commit("Add welcome source")
(repository / "App").mkdir()
git("mv", "Sources/Welcome.swift", "App/Welcome.swift")
renamed = commit("Move welcome into App")
write("App/Welcome.swift", 'let title = "GitPico"\nlet spacing = 14\nlet showGraph = true\n')
edited = commit("Tune native spacing", "Maya", "maya@example.invalid")
write("App/Welcome.swift", 'let title = "A little clarity"\nlet spacing = 14\nlet showGraph = true\n')
title = commit("Polish welcome title")
write("Notes.md", "Inspect File History, Blame and Compare, then revert this note commit.\n")
head = commit("Add inspection notes")
report = dict(repository=str(repository), base=base, added=added, renamed=renamed, edited=edited, title=title, head=head, file="App/Welcome.swift")
(repository.parent / (repository.name + ".json")).write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
