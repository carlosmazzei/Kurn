import re
import unittest
from pathlib import Path


ACTION_PATH = Path(__file__).resolve().parents[2] / ".github/actions/cache-spm-packages/action.yml"


class SPMCachePolicyTests(unittest.TestCase):
    def test_cache_key_tracks_all_dependency_pins(self):
        action = ACTION_PATH.read_text(encoding="utf-8")
        match = re.search(r"(?m)^\s*key:\s*(.+)$", action)
        self.assertIsNotNone(match)
        for path in (
            "Kurn.xcodeproj/project.pbxproj",
            "Kurn.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "Packages/WhisperCpp/Package.swift",
        ):
            with self.subTest(path=path):
                self.assertIn(f"'{path}'", match.group(1))

    def test_restore_cannot_fall_back_to_an_older_checkout(self):
        action = ACTION_PATH.read_text(encoding="utf-8")
        self.assertNotRegex(action, r"(?m)^\s*restore-keys\s*:")

    def test_cache_contains_package_sources_not_build_products(self):
        action = ACTION_PATH.read_text(encoding="utf-8")
        match = re.search(r"(?m)^\s*path:\s*(.+)$", action)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "${{ runner.temp }}/DerivedData/SourcePackages")


if __name__ == "__main__":
    unittest.main()
