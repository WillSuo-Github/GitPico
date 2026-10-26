# Maturity implementation — 2026-10-26

Authorized scope: implement the remaining maturity gaps discussed after acceptance commit `18be8be`. Keep version 0.01 and minimum macOS 26.0. This is an implementation tracker, not a claim of runtime acceptance.

## Work list

- [x] Open repositories with unresolved upstreams and expose repair actions.
- [x] Pull policy preferences, per-operation review, merge/rebase and divergence recovery.
- [x] Persist and restore native workspace groups, tab order, active selection and repository navigation.
- [x] Image comparison, binary information and broader history review.
- [x] OAuth/network failure handling and expiry/revocation coverage.
- [x] Hosted PR/MR workflows and configurable enterprise/self-managed accounts.
- [x] SSH key management and LFS locking workflows.
- [x] CI, signing/notarization packaging, update delivery and diagnostic export.
- [x] Background performance samples and light/dark offscreen feature captures.
- [ ] External acceptance: live new PR/MR/API grants, enterprise servers, production notarization/update loop, macOS 26/Intel runtime, prolonged sleep/network behavior and foreground IME/VoiceOver.

## Validation policy

Use disposable repositories for writes and background tests by default. Do not overlap hosted tests with live OAuth. Record unavailable external credentials, macOS 26/Intel hosts, physical IME/VoiceOver and signing/update-service requirements as unresolved acceptance gates. Implementation and foreground/production acceptance are separate results.

## Current result

Implementation was validated in the working tree based on `18be8be`, before source delivery. Subsequent commits/pushes are recorded in Git history. No draft release upload or publication was performed. GitHub Releases hosting targets the existing private repository and requires an authorized account. The staged development build omits the publisher public key, so update checking remains disabled until distribution setup and acceptance. See [validation](VALIDATION-MATURITY-IMPLEMENTATION-2026-10-26.md) and [distribution setup](DISTRIBUTION.md).
