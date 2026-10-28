import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("localizations", Path(__file__).parents[1] / "validate_localizations.py")
localizations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localizations)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


class LocalizationValidationTests(unittest.TestCase):
    def check(self, key, localization):
        catalog = {"sourceLanguage": "en", "strings": {key: {"localizations": localization}}}
        return localizations.validate_catalog(catalog, ["de"])[1]

    def test_numbered_arguments_can_change_order(self):
        self.assertFalse(self.check("Move %@ to %@", {"de": unit("%2$@ ist das Ziel für %1$@")}))

    def test_dropped_repeated_and_wrongly_typed_arguments_fail(self):
        for value in ("Verschiebe %@", "Verschiebe %1$@ nach %1$@", "Verschiebe %@ nach %lld"):
            self.assertTrue(self.check("Move %@ to %@", {"de": unit(value)}))

    def test_literal_percent_and_line_breaks_are_checked(self):
        self.assertTrue(self.check("Progress %lld%%\nDone", {"de": unit("Fortschritt %lld%\nFertig")}))
        self.assertTrue(self.check("Progress %lld%%\nDone", {"de": unit("Fortschritt %lld%% Fertig")}))

    def test_missing_or_unfinished_translation_fails(self):
        self.assertTrue(self.check("Working Copy", {}))
        self.assertTrue(self.check("Working Copy", {"de": {"stringUnit": {"state": "new", "value": "Arbeitskopie"}}}))

    def test_git_file_names_and_product_names_remain_literal(self):
        self.assertTrue(self.check("Open .gitmodules in GitPico", {"de": unit("Öffne .gitmodule in GitPico")}))
        self.assertFalse(self.check("Open .gitmodules in GitPico", {"de": unit("Öffne .gitmodules in GitPico")}))

    def test_plural_categories_and_singular_spelled_out_count(self):
        source = {"variations": {"plural": {"one": unit("1 file"), "other": unit("%lld files")}}}
        target = {"variations": {"plural": {"one": unit("1 Datei"), "other": unit("%lld Dateien")}}}
        self.assertFalse(self.check("%lld files", {"en": source, "de": target}))
        del target["variations"]["plural"]["one"]
        self.assertTrue(self.check("%lld files", {"en": source, "de": target}))


if __name__ == "__main__":
    unittest.main()
