import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('select_github_draft', Path(__file__).parents[1] / 'select_github_draft.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DraftSelectionTests(unittest.TestCase):
    def test_finds_exact_draft_across_pages(self):
        expected = {'tag_name': 'build-123', 'draft': True, 'assets': [{'id': 42}]}
        self.assertEqual(module.select([[{'tag_name': 'build-12', 'draft': True}], [expected]], 'build-123'), expected)

    def test_refuses_missing_duplicate_or_published_release(self):
        draft = {'tag_name': 'build-123', 'draft': True}
        for pages in ([], [[draft, draft]], [[dict(draft, draft=False)]], [[{'tag_name': 'other', 'draft': True}]]):
            with self.assertRaises(ValueError):
                module.select(pages, 'build-123')

    def test_refuses_unexpected_response_shape(self):
        for pages in ({}, [{'tag_name': 'build-123', 'draft': True}]):
            with self.assertRaises(ValueError):
                module.select(pages, 'build-123')
