import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from normalize_notarization import normalize


class NotarizationTests(unittest.TestCase):
    def test_accepts_both_provider_receipt_shapes(self):
        expected = {'id': 'fixture-submission', 'status': 'Accepted'}
        self.assertEqual(normalize(expected), expected)
        self.assertEqual(normalize({'data': {'id': 'fixture-submission', 'attributes': {'status': 'Accepted'}}}), expected)

    def test_rejects_invalid_incomplete_and_unidentified_receipts(self):
        for value in ({}, [], {'status': 'Accepted'}, {'id': 'fixture', 'status': 'Invalid'},
                      {'data': {'id': 'fixture', 'attributes': {'status': 'In Progress'}}}):
            with self.assertRaises(ValueError):
                normalize(value)
