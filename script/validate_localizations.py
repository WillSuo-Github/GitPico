#!/usr/bin/env python3
"""Validate shipping String Catalog coverage, printf arguments and plural forms."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SPECIFIER = re.compile(r"%%|%(?:(\d+)\$)?(lld|ld|d|@|(?:\.\d+)?f)")
PLURALS = {"zero", "one", "two", "few", "many", "other"}
PROTECTED_TOKENS = ("GitPico", "GitHub", "GitLab", "HEAD", "SSH_AUTH_SOCK", ".gitmodules", ".gitattributes", ".gitignore", "--force-with-lease", "--allow-unrelated-histories", "core.sshCommand")
# CLDR cardinal forms. Unspecified languages use one/other.
CATEGORIES = {
    "ar": PLURALS,
    "cs": {"one", "few", "many", "other"},
    "sk": {"one", "few", "many", "other"},
    "he": {"one", "two", "other"},
    "hr": {"one", "few", "other"},
    "pl": {"one", "few", "many", "other"},
    "ro": {"one", "few", "other"},
    "ru": {"one", "few", "many", "other"},
    "uk": {"one", "few", "many", "other"},
    "sl": {"one", "two", "few", "other"},
}
for _language in ("ca", "es", "es-419", "fr", "fr-CA", "it", "pt-BR", "pt-PT"):
    CATEGORIES[_language] = {"one", "many", "other"}
for _language in ("id", "ja", "ko", "ms", "th", "vi", "zh-Hans", "zh-Hant", "zh-HK"):
    CATEGORIES[_language] = {"other"}


def arguments(value):
    """Keep positional identities, types and literal percent escapes."""
    result = []
    implicit = 0
    for match in SPECIFIER.finditer(value):
        if match[0] == "%%":
            result.append((0, "%"))
        else:
            implicit += 1
            result.append((int(match[1]) if match[1] else implicit, match[2]))
    return Counter(result)


def values(localization):
    if "stringUnit" in localization:
        return {None: localization["stringUnit"]}
    return {form: item.get("stringUnit", {}) for form, item in
            localization.get("variations", {}).get("plural", {}).items()}


def validate_catalog(catalog, languages):
    errors = []
    source = catalog["sourceLanguage"]
    count = 0
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        # Interpolation-only keys, symbols and status letters carry no prose.
        prose = SPECIFIER.sub("", key)
        if not re.search(r"[A-Za-z]{2}", prose):
            continue
        count += 1
        original = entry.get("localizations", {}).get(source, {})
        original_values = values(original)
        plural = bool(original.get("variations", {}).get("plural"))
        generic = original_values.get("other", original_values.get(None, {})).get("value", key)
        for language in languages:
            translated = entry.get("localizations", {}).get(language)
            label = f"{language}: {key!r}"
            if translated is None:
                errors.append(f"{label}: missing translation")
                continue
            units = values(translated)
            required = CATEGORIES.get(language, {"one", "other"}) if plural else {None}
            if set(units) != required:
                errors.append(f"{label}: expected forms {sorted(str(x) for x in required)}, got {sorted(str(x) for x in units)}")
            for form, unit in units.items():
                value = unit.get("value")
                if unit.get("state") != "translated" or not isinstance(value, str) or not value.strip():
                    errors.append(f"{label}/{form}: empty or unfinished translation")
                    continue
                # A singular source may spell out 1 rather than interpolate its count.
                candidates = [generic]
                if form == "one":
                    candidates.append(original_values.get("one", {}).get("value", generic))
                if not any(arguments(value) == arguments(candidate) for candidate in candidates):
                    errors.append(f"{label}/{form}: format arguments differ")
                if value.count("\n") != generic.count("\n"):
                    errors.append(f"{label}/{form}: newline count differs")
                for token in PROTECTED_TOKENS:
                    if token in key and token not in value:
                        errors.append(f"{label}/{form}: missing literal token {token}")
    return count, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--language", action="append", help="Validate only this language (repeatable). Default: all shipping languages.")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "Configuration/Localizations.json").read_text())
    languages = args.language or manifest["localizations"]
    if set(languages) - set(manifest["localizations"]):
        parser.error("Unknown language; use a code from Configuration/Localizations.json")
    failures = 0
    for target in ("GitCore", "GitPico"):
        path = ROOT / "Sources" / target / "Localizable.xcstrings"
        catalog = json.loads(path.read_text())
        if catalog["sourceLanguage"] != manifest["sourceLanguage"]:
            parser.error(f"{path}: source language differs from manifest")
        count, errors = validate_catalog(catalog, languages)
        print(f"{target}: {count} localizable keys, {len(languages)} languages, {len(errors)} errors")
        for error in errors[:30]:
            print(f"  {error}")
        failures += len(errors)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
