"""Tests for Tools/xccov_to_lcov.py's parsing (run in the static-policy job).

`xccov` itself needs Xcode, so these replace the subprocess call with canned
output and check both the single-read JSON path and its per-file fallback.
"""

import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import xccov_to_lcov  # noqa: E402

ARCHIVE_JSON = {
    "/src/Kurn/A.swift": [
        {"line": 1, "isExecutable": False, "executionCount": None, "subranges": []},
        {"line": 2, "isExecutable": True, "executionCount": 3, "subranges": []},
        {"line": 3, "isExecutable": True, "executionCount": 0, "subranges": []},
    ],
    "/src/KurnTests/ATests.swift": [
        {"line": 1, "isExecutable": True, "executionCount": 1, "subranges": []},
    ],
    "/src/Kurn/Empty.swift": [
        {"line": 1, "isExecutable": False, "executionCount": None, "subranges": []},
    ],
}


def keep(path: str) -> bool:
    return "Tests" not in path


class JSONPathTests(unittest.TestCase):
    def test_reads_every_file_from_one_call(self):
        with mock.patch.object(xccov_to_lcov, "xccov", return_value=json.dumps(ARCHIVE_JSON)) as call:
            records = xccov_to_lcov.records_from_json("bundle", keep)
        call.assert_called_once_with("--json", "bundle")
        self.assertEqual(set(records), {"/src/Kurn/A.swift", "/src/Kurn/Empty.swift"})
        self.assertEqual(
            records["/src/Kurn/A.swift"],
            "SF:/src/Kurn/A.swift\nDA:2,3\nDA:3,0\nLF:2\nLH:1\nend_of_record\n",
        )
        self.assertEqual(records["/src/Kurn/Empty.swift"], "")

    def test_unrecognised_shape_returns_none(self):
        for output in ("[]", "{}", json.dumps({"/a.swift": "text"}), json.dumps({"/a.swift": [{"x": 1}]}), "not json"):
            with mock.patch.object(xccov_to_lcov, "xccov", return_value=output):
                self.assertIsNone(xccov_to_lcov.records_from_json("bundle", keep), output)


class PerFileFallbackTests(unittest.TestCase):
    def test_parses_the_text_report(self):
        def fake(*args):
            if args[0] == "--file-list":
                return "/src/Kurn/A.swift\n/src/KurnTests/ATests.swift\n"
            return "    1: *\n    2: 3\n    3: 0\n"

        with mock.patch.object(xccov_to_lcov, "xccov", side_effect=fake):
            records = xccov_to_lcov.records_per_file("bundle", keep)
        self.assertEqual(
            records,
            {"/src/Kurn/A.swift": "SF:/src/Kurn/A.swift\nDA:2,3\nDA:3,0\nLF:2\nLH:1\nend_of_record\n"},
        )


if __name__ == "__main__":
    unittest.main()
