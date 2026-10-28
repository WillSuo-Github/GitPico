# Localization

GitPico follows the macOS per-application language. The source language is English;
`Configuration/Localizations.json` declares 37 additional languages and regional variants.
This is a language list, not a list of countries.

## Catalogs and display boundaries

- `Sources/GitPico/Localizable.xcstrings` owns app windows, menus, settings and progress text.
- `Sources/GitCore/Localizable.xcstrings` owns GitCore errors and user-facing operation summaries.
- Xcode compiles the app catalog into the main bundle and the core catalog into the embedded framework.
  SwiftPM processes each catalog in its target's resource bundle. Core lookups use `#bundle`.
- Use literal SwiftUI text where possible. Carry `LocalizedStringResource` through shared controls;
  use `String(localized:)` for AppKit and other APIs that require a resolved string.
- Keep a complete sentence in one localization key, with interpolated values. Do not assemble prose
  from independently translated fragments. Pluralized counts use catalog variations.
- Persisted identifiers, enum raw values, Git commands, paths, user-authored text, raw Git output and
  AI prompt instructions remain data. Translate known status identifiers only when presenting them.
  Never branch on a translated title or error message; use stable properties or error reasons.
- App window roots, Settings and the search suggestions panel follow the preferred language's
  writing direction. Code/diff rows keep their source-column order and left-to-right layout.

## Updating strings

1. Edit the owning Swift source, then build the native Xcode target. Compiler extraction updates
   the existing catalogs (`SWIFT_EMIT_LOC_STRINGS` and `LOCALIZATION_PREFERS_STRING_CATALOGS`).
2. Translate new or changed keys in every declared localization. Preserve printf argument types
   and identities; use positional arguments when the target language changes word order. Preserve
   line breaks and percent escapes. Supply the locale's cardinal plural categories.
3. For language-list changes, update the manifest and regenerate through
   `./script/generate_project.sh`. Its final step registers regions hidden by synchronized groups.
4. Run the catalog validator and tests, then build the native app and verify its resource lookup.

```sh
python3 script/validate_localizations.py
python3 -m unittest discover -s script/tests
swift test
./script/build_and_run.sh --verify
python3 script/verify_localizations.py
```

The runtime verifier launches a separate suppressed process for every language, using argument-domain
language preferences. It checks the app catalog, GitCore catalog, singular/plural output and zero visible
windows. It does not change system preferences or open a repository. `--app` selects another built app;
repeat `--language` to narrow verification.

`renderLocalizedPanelsWithoutWindows()` is an opt-in native Xcode test. Set
`GITPICO_CAPTURE_LOCALIZATIONS=1` and `GITPICO_LOCALIZATION_OUTPUT` to a temporary output directory,
and use the desired test language. The normal test scheme intentionally uses English because existing
workflow assertions inspect English messages. Capture only this test when overriding that language.

Format and coverage checks do not establish native-speaker review of every translation. Git output,
repository content and editable AI instructions can contain their original language.
