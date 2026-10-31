"""Tests for Tools/validate_store_metadata.py (run in the static-policy job)."""

import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import validate_store_metadata as vsm  # noqa: E402

GOOD = {
    "name.txt": "Kurn: AI Meeting Note Taker",
    "subtitle.txt": "Record, Transcribe, Summarize",
    "keywords.txt": "transcription,voice,audio,offline",
    "promotional_text.txt": "Private meeting notes.",
    "description.txt": "Kurn records meetings.",
    "release_notes.txt": "Fixes.",
    "marketing_url.txt": "https://example.com",
    "privacy_url.txt": "https://example.com/privacy",
    "support_url.txt": "https://example.com/support",
}


def make_metadata(root: Path, locales, overrides=None, root_files=None):
    for locale in locales:
        directory = root / locale
        directory.mkdir(parents=True)
        files = dict(GOOD, **(overrides or {}).get(locale, {}))
        for name, value in files.items():
            (directory / name).write_text(value + "\n", encoding="utf-8")
    files = {"copyright.txt": "2026 Someone", "primary_category.txt": "PRODUCTIVITY",
             "secondary_category.txt": "BUSINESS"}
    files.update(root_files or {})
    for name, value in files.items():
        (root / name).write_text(value + "\n", encoding="utf-8")


def run(root: Path, locales):
    with redirect_stdout(io.StringIO()):
        return vsm.validate(root, set(locales))


class KeywordHygieneTests(unittest.TestCase):
    def test_clean_keywords_pass(self):
        self.assertEqual(vsm.keyword_problems("transcription,voice", "Kurn: AI Notes", "Record audio"), [])

    def test_words_already_in_name_or_subtitle_are_wasted(self):
        problems = vsm.keyword_problems("meeting,record,voice", "Kurn: AI Meeting Notes", "Record audio")
        self.assertEqual(len(problems), 2)
        self.assertTrue(all("already in the name or subtitle" in p for p in problems))

    def test_spacing_duplicates_brand_and_category_are_flagged(self):
        problems = vsm.keyword_problems("voice, Voice,,kurn,productivity", "Kurn", "Notes")
        joined = " ".join(problems)
        self.assertIn("spaces around commas", joined)
        self.assertIn("empty entry", joined)
        self.assertIn("repeated", joined)
        self.assertIn("app name", joined)
        self.assertIn("category", joined)

    def test_cjk_keywords_are_compared_by_substring(self):
        self.assertEqual(len(vsm.keyword_problems("会议纪要", "Kurn：AI 会议纪要", "摘要")), 1)
        self.assertEqual(vsm.keyword_problems("会议记录", "Kurn：AI 会议纪要", "摘要"), [])

    def test_competitor_names_are_refused(self):
        self.assertTrue(vsm.competitor_problems("Better than Otter and Plaud"))
        self.assertEqual(vsm.competitor_problems("Pinch to zoom your teams notes"), [])


class ValidateTests(unittest.TestCase):
    def test_complete_metadata_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_metadata(root, ["en-US", "pt-BR"])
            self.assertEqual(run(root, ["en-US", "pt-BR"]), [])

    def test_missing_locale_and_limits_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_metadata(root, ["en-US"], {"en-US": {"subtitle.txt": "x" * 31, "support_url.txt": "http://a"}})
            errors = " ".join(run(root, ["en-US", "es-MX"]))
            self.assertIn("missing=['es-MX']", errors)
            self.assertIn("1-30 characters; found 31", errors)
            self.assertIn("HTTPS", errors)

    def test_keyword_byte_limit_counts_utf8(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_metadata(root, ["zh-Hans"], {"zh-Hans": {"keywords.txt": "录" * 34}})
            self.assertIn("found 102", " ".join(run(root, ["zh-Hans"])))

    def test_listing_rules_are_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_metadata(
                root, ["en-US"],
                {"en-US": {"name.txt": "Meeting Notes", "subtitle.txt": "Meeting Notes",
                           "keywords.txt": "notes,otter", "description.txt": "Like Granola."}},
                root_files={"secondary_category.txt": "PRODUCTIVITY"},
            )
            errors = " ".join(run(root, ["en-US"]))
            self.assertIn("brand name", errors)
            self.assertIn("only repeats the name", errors)
            self.assertIn("already in the name or subtitle", errors)
            self.assertIn("Guideline 2.3.7", errors)
            self.assertIn("must differ from the primary", errors)

    def test_repository_metadata_is_valid(self):
        with redirect_stdout(io.StringIO()):
            self.assertEqual(vsm.main(), 0)


if __name__ == "__main__":
    unittest.main()
