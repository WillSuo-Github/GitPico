# GitHub Releases and signed updates

GitPico uses the public `WillSuo-Github/GitPico` repository for distribution. Readers do not need a GitHub account or token to download releases. This document describes the implemented workflow; no release is published by building or running tests.

Validation, builds, signing, notarization and packaging run locally. GitHub Actions CI is intentionally removed; GitHub hosts the source and release assets. Release preparation uses a clean, committed `main` checkout.

## Publisher setup

Keep marketing version `0.01` until release preparation is explicitly requested. Builds receive Shanghai date/time build numbers. Packages target macOS 26.0 and both arm64/x86_64.

Set these values locally, using the intended Apple Developer account:

`Configuration/Distribution.json` now supplies the personal publisher team `NT9VR9C9HY`, its matching Developer ID identity and local ASC profile `Mac mini`. The certificate serial returned by that ASC profile matched the installed personal certificate; its Notary API history was readable. Environment variables override these nonsecret defaults. `Configuration/SparklePublicKey.txt` contains only GitPico's dedicated public verification key; the private key stays in the `com.willsuo.GitPico.updates` Keychain account. Do not regenerate/replace this key for subsequent updates.

- `GITPICO_SIGNING_IDENTITY`: matching `Developer ID Application:` identity.
- `GITPICO_TEAM_ID`: the identity's Apple Developer team.
- `GITPICO_NOTARY_PROFILE`: an existing `notarytool` Keychain profile.
- `GITPICO_ASC_PROFILE`: an existing ASC CLI profile as an alternative notarization route, without exporting its API key.
- `GITPICO_UPDATE_PUBLIC_KEY`: public Ed25519 key, defaulting to the committed public key file.
- Optional `GITPICO_SPARKLE_ACCOUNT`: default `com.willsuo.GitPico.updates`.

The Sparkle tools are downloaded by Xcode's pinned Sparkle 2.10.1 dependency. To create the dedicated signing key, run the vendor `generate_keys --help` and use its `--account` option with that dedicated account. Keep the private key in Keychain and retain a secure backup. Never commit or paste the private key or GitHub tokens into configuration, feeds, logs or release notes. The public key is compiled into the distributed app.

`GITPICO_UPDATE_FEED_URL` defaults to the repository's latest Release appcast URL. Sparkle reads this public download URL directly, without any GitHub REST API calls. GitHub redirects the public feed and archive to its HTTPS asset CDN. Set `GITPICO_SPARKLE_BIN` only when using a different local vendor tools directory. To use another hosting service, remove `GitPicoUpdateRepository` from the source configuration and supply its HTTPS feed/download prefix; do not mix private GitHub headers with another host.

## Prepare and review

1. Commit reviewed source and run the background validation suite. Packaging and draft upload reject a dirty checkout.
2. Run `./script/package_release.sh`. It archives a universal hardened-runtime app, checks its signature/architectures, submits to notarization, requires `Accepted`, staples and validates the ticket, checks Gatekeeper, creates the ZIP and signs the archive/feed. Output lives in `dist/releases/<build>/` with notarization results and a source-commit/archive-hash manifest.
3. Run `./script/publish_github_release.sh dist/releases/<build>`. It requires authenticated publisher `gh` access to the public repository, verifies the manifest against the current commit, creates/resumes a **draft** `build-<build>` release and uploads the archive. Existing archive bytes must match; it never replaces a conflicting binary. It binds the appcast enclosure to the build's exact public GitHub ZIP download URL, re-signs the feed with the vendor tool and uploads appcast.xml. This command never publishes the draft.
4. Review the draft, source commit, validation, signatures and notarization before publishing it as the latest non-prerelease. Publication is a separate action. Do not delete/re-upload an archive after binding its ID in the feed; prepare a new build instead.

A failed upload can be resumed using the same directory. Retain local output/logs until the published upgrade has been accepted. The appcast validator checks required fields and expected URLs, while Sparkle performs cryptographic signature verification; the Python validator is not a signature verifier.

## Client behavior and limits

Sparkle reads the public signed feed and installation archive directly, without GitHub REST requests, account selection, Keychain access, OAuth refresh or Authorization headers. Public archive requests disable cookies. The enclosure must match this repository's `build-<date>/GitPico-<date>.zip` URL and the offered build number; unrelated repositories, asset names and versions are rejected. External release-note downloads are disabled. Sparkle verifies the publisher's signed feed and archive before extraction/installation. Automatic checking is initially off and can be enabled in Settings; automatic installation is not enabled.

Normal Xcode/local builds load the committed public key and derive the GitHub feed from the configured repository, just as distribution builds do. An explicit empty `GITPICO_UPDATE_PUBLIC_KEY` disables this default; a build without a verification key keeps update actions disabled. Manual checks use Sparkle's native progress, cancellation and error UI immediately. Public download URLs avoid the anonymous GitHub REST API quota; no account setup is required.

Earlier clients, including the withdrawn REST-based transition build `20261027163952`, use account-gated or rate-limited REST lookups. Users of these earlier clients must manually install a newer signed public-update build once; subsequent updates require no account. Existing Git hosting accounts remain independent of software updates.

## Acceptance gates

The Developer ID/notarization/stapling/Gatekeeper pipeline and the private update/install/relaunch loop passed for builds `20261027001805` → `20261027002242`; both were published privately under explicit authorization. The first pre-fix loop failed because Sparkle received JSON metadata and its release was returned to draft. Older builds containing that resolver bug require manual installation of a fixed package. See [exact results and evidence](COMPLETION-2026-10-26.md).

Removing CI does not establish platform/runtime acceptance. Record the actual local host and architectures tested for each release; a universal archive alone does not prove runtime behavior on both architectures. Update rollback/recovery, physical IME/VoiceOver, prolonged sleep/network/revocation behavior and wider production acceptance remain separate gates. Earlier CI results remain in their historical validation records.

References: [Sparkle publishing](https://sparkle-project.org/documentation/publishing/), [GitHub release assets](https://docs.github.com/en/rest/releases/assets), [Sparkle updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html).
