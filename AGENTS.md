# GitPico development agreements

- Until the user explicitly starts release preparation, keep `CFBundleShortVersionString` fixed at `0.0.1`. Do not increase it for development feature batches.
- Generate a new `CFBundleVersion` for each staged app build using the current Asia/Shanghai date and time in `yyyyMMddHHmmss` form. Display the bundle values in Settings instead of duplicating version strings in Swift.
- Keep the minimum macOS deployment target at 26.0. Do not represent testing on a newer macOS host as runtime acceptance on macOS 26.
- Exercise Git write workflows in disposable local repositories. Do not use personal repositories or external servers for acceptance writes without explicit authorization.
- Historical validation documents keep the version names used at their capture time. New validation records use a date/build identifier, not a new marketing version.
- Test in the background by default. Do not activate, raise or cover the user's foreground workspace with GitPico, Tower, browser or other app windows during testing. Use builds, isolated Git tests, logs and `--verify` (suppressed windows, no activation). Do not resume foreground UI/mouse testing unless the user explicitly asks for it.

## Native Xcode project

- `GitPico.xcodeproj` and its shared `GitPico` scheme are the normal app Run/Test entry point; keep the generated project in source control together with `project.yml`.
- `Sources/GitCore`, `Sources/GitPico` and both `Tests` folders use synchronized Xcode groups and remain shared with `Package.swift`; do not copy source files into a second project tree.
- Regenerate target, scheme or build-setting changes through `./script/generate_project.sh` (XcodeGen 2.46+). Opening and building the saved project must not require XcodeGen.
- Xcode generates the app Info.plist in DerivedData through `script/xcode_build_metadata.py`; never mutate the source plist or project file to increment a build. Keep marketing version `0.0.1` and the macOS target `26.0`.
- Keep the shared scheme's Test action windowless (`--background-testing`); its Run action must launch the normal app when explicitly invoked by the user.

## Local validation and releases

- Run validation, builds, Developer ID signing, notarization and packaging locally. Do not add or enable GitHub Actions CI unless the user explicitly requests it.
- Prepare releases from a clean, committed `main` checkout using `script/package_release.sh`, then upload the signed package and appcast to GitHub Releases. Verify uploaded assets and the signed feed before publishing an authorized release as Latest.
