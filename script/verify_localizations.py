#!/usr/bin/env python3
"""Verify translations in a built native app without presenting windows or changing preferences."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def translated(catalog, key, language, form=None):
    if language == "en" and form is None:
        return key
    entry = catalog["strings"][key]["localizations"][language]
    if form is not None:
        entry = entry["variations"]["plural"][form]
    return entry["stringUnit"]["value"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/GitPico.app")
    parser.add_argument("--language", action="append")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "Configuration/Localizations.json").read_text())
    languages = args.language or ["en"] + manifest["localizations"]
    executable = args.app.resolve() / "Contents/MacOS/GitPico"
    catalogs = {name: json.loads((ROOT / "Sources" / name / "Localizable.xcstrings").read_text()) for name in ("GitCore", "GitPico")}
    with tempfile.TemporaryDirectory(prefix="GitPico-localization-verification-") as directory:
        for language in languages:
            output = Path(directory) / f"{language}.json"
            subprocess.run([str(executable), "-AppleLanguages", f"({language})", "--background-testing", "--verify-localizations", "--verification-output", str(output), "--verification-exit"], check=True, timeout=15, capture_output=True)
            report = json.loads(output.read_text())
            assert report["backgroundTesting"] and not report["isActive"] and report["visibleWindows"] == 0, report
            assert report["frontmostProcessIdentifier"] != report["processIdentifier"], report
            value = report["localization"]
            # String Catalog compilation canonicalizes legacy Norwegian "no" to Bokmål "nb".
            expected_language = {"no": "nb"}.get(language, language)
            assert value["preferredLanguages"][0] == expected_language, value
            assert value["workingCopy"] == translated(catalogs["GitPico"], "Working Copy", language), value
            assert value["modifiedStatus"] == translated(catalogs["GitCore"], "Modified", language), value
            assert value["appError"] == translated(catalogs["GitPico"], "Result is not UTF-8 text.", language), value
            for count, property_name in ((1, "oneChangedFile"), (3, "threeChangedFiles")):
                entry = catalogs["GitPico"]["strings"]["%lld changed files"]["localizations"][language]
                forms = entry["variations"]["plural"]
                if language in ("ar", "hr", "pl", "ro", "ru", "sk", "sl", "cs", "uk") and count == 3:
                    form = "few"
                else:
                    form = "one" if count == 1 and "one" in forms else "other"
                expected = forms[form]["stringUnit"]["value"].replace("%1$lld", str(count)).replace("%lld", str(count))
                assert value[property_name] == expected, (language, property_name, expected, value)
            print(f"{language}: app text, GitCore text, singular/plural and background launch verified", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
