#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/dist/PicoDemo"
if [[ -d "$DEMO_DIR/.git" ]]; then echo "Demo already exists: $DEMO_DIR"; exit 0; fi
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"
git init -b main
git config user.name "Pico Team"
git config user.email "hello@example.invalid"
git config commit.gpgsign false
git config core.hooksPath /dev/null
mkdir -p Sources Docs
cat > README.md <<'EOF'
# Pico Demo

A local playground for exploring GitPico.

This is a real Git repository. Try staging a file, writing a commit,
and browsing the history. Changes here only affect this demo.
EOF
git add README.md
git commit -m "Start a little home for our next idea"
cat > Sources/Greeting.swift <<'EOF'
import Foundation

struct Greeting {
    let name: String

    var message: String {
        "Hello, \(name)!"
    }
}
EOF
git add Sources
git commit -m "Add a friendly greeting"
git switch -c feature/welcome
cat > Sources/Welcome.swift <<'EOF'
import SwiftUI

struct Welcome: View {
    var body: some View {
        Text("Welcome to Pico")
            .font(.title)
    }
}
EOF
git add Sources/Welcome.swift
git commit -m "Build a native welcome screen"
git switch main
echo 'Keep each commit focused on one idea.' > Docs/Contributing.md
git add Docs
git commit -m "Document our contribution workflow"
git merge --no-ff feature/welcome -m "Merge the welcome screen"
git tag v0.1.0
git switch -c feature/polish
echo 'Prefer system colors and native controls.' >> Docs/Contributing.md
git add Docs
git commit -m "Write down native interface conventions"
cat > Sources/Greeting.swift <<'EOF'
import Foundation

struct Greeting {
    let name: String

    var message: String {
        "Welcome back, \(name)!"
    }
}
EOF
git add Sources/Greeting.swift
cat > Docs/Notes.md <<'EOF'
# Ideas for a quieter workflow

- Make changes easy to review.
- Keep branches close at hand.
- Show the full story behind every commit.
EOF
echo '' >> README.md
echo 'Built with SwiftUI for macOS 26.' >> README.md
echo "Created demo: $DEMO_DIR"
