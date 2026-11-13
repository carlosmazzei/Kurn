import copy
from pathlib import Path
import tempfile
import unittest

from Tools.check_native_harness_contracts import CATALOG, read_json, validate


class NativeHarnessContractTests(unittest.TestCase):
    root = Path(__file__).resolve().parents[2]

    def setUp(self):
        self.manifest = read_json(self.root / CATALOG)

    def test_repository_catalog_and_frozen_evidence_are_valid(self):
        self.assertEqual(validate(self.root), [])

    def test_missing_and_duplicate_criteria_fail(self):
        for collection in ("components", "acceptance"):
            value = copy.deepcopy(self.manifest)
            value[collection].pop()
            self.assertTrue(any(collection in error for error in validate(self.root, value)))
            value = copy.deepcopy(self.manifest)
            value[collection][-1] = value[collection][0]
            self.assertTrue(any(collection in error for error in validate(self.root, value)))

    def test_unknown_versions_and_boolean_versions_fail(self):
        for key in ("manifestVersion", "contractVersion"):
            for version in (2, True, "1"):
                value = copy.deepcopy(self.manifest)
                value[key] = version
                self.assertTrue(any(key in error for error in validate(self.root, value)))

    def test_legacy_evidence_cannot_be_labeled_as_verified_target(self):
        value = copy.deepcopy(self.manifest)
        value["acceptance"][0]["targetStatus"] = "verified"
        value["acceptance"][0]["targetEvidence"] = []
        self.assertTrue(any("verified target needs target evidence" in error for error in validate(self.root, value)))

    def test_partial_target_evidence_is_distinct_from_legacy_and_full_verification(self):
        value = copy.deepcopy(self.manifest)
        item = next(item for item in value["acceptance"] if item["id"] == "A09")
        item.update(targetStatus="partial", baselineEvidence=[], targetEvidence=[{
            "path": "Packages/AgentHarness/Tests/AgentHarnessTests/AgentContentContractTests.swift",
            "symbol": "providerBoundaryAlwaysEmitsOneTerminal",
        }])
        self.assertEqual(validate(self.root, value), [])
        item["targetEvidence"] = []
        self.assertTrue(any("A09: partial status needs" in error for error in validate(self.root, value)))

    def test_stale_test_symbols_and_missing_files_fail(self):
        for item in ({"path": "missing-test.swift"},
                     {"path": "KurnTests/NativeHarnessContractFixtureTests.swift", "symbol": "removedTest"}):
            value = copy.deepcopy(self.manifest)
            value["acceptance"][0]["baselineEvidence"] = [item]
            self.assertTrue(any("A01.baselineEvidence" in error for error in validate(self.root, value)))

    def test_fixture_changes_need_explicit_catalog_review(self):
        value = copy.deepcopy(self.manifest)
        value["fixtures"][0]["sha256"] = "0" * 64
        self.assertTrue(any("fixture checksum changed" in error for error in validate(self.root, value)))

    def test_native_golden_is_validated_separately_from_legacy_baseline(self):
        value = copy.deepcopy(self.manifest)
        value["contractFixtures"][0]["sha256"] = "0" * 64
        self.assertTrue(any("contract fixture checksum changed" in error for error in validate(self.root, value)))
        value["contractFixtures"] = None
        self.assertTrue(any("contractFixtures: expected array" in error for error in validate(self.root, value)))
        value["contractFixtures"] = [False]
        self.assertTrue(any("invalid contract fixture" in error for error in validate(self.root, value)))

    def test_paths_cannot_escape_the_repository(self):
        for path in ("../outside.json", "/tmp/outside.json"):
            value = copy.deepcopy(self.manifest)
            value["fixtures"][0]["path"] = path
            self.assertTrue(any("repository-relative" in error for error in validate(self.root, value)))

    def test_excluded_subsystems_cannot_claim_target_completion(self):
        value = copy.deepcopy(self.manifest)
        item = next(item for item in value["components"] if item["id"] == "C22")
        item.update(disposition="required", targetStatus="verified", increment="NH04",
                    targetEvidence=[{"path": "KurnTests/NativeHarnessContractFixtureTests.swift"}])
        self.assertTrue(any("C22: external/virtual" in error for error in validate(self.root, value)))
        value = copy.deepcopy(self.manifest)
        value["profileConstraints"]["backend"] = True
        self.assertTrue(any("app-only" in error for error in validate(self.root, value)))

    def test_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            path.write_text('{"fixtureVersion":1,"fixtureVersion":2}')
            with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
                read_json(path)

    def test_malformed_record_types_fail_with_validation_errors(self):
        for key, invalid in (("specReference", []), ("nativeCases", None)):
            value = copy.deepcopy(self.manifest)
            value[key] = invalid
            self.assertTrue(validate(self.root, value))
        value = copy.deepcopy(self.manifest)
        value["components"][0]["id"] = []
        self.assertTrue(validate(self.root, value))
        value = copy.deepcopy(self.manifest)
        value["profileConstraints"]["backend"] = 0
        self.assertTrue(validate(self.root, value))


if __name__ == "__main__":
    unittest.main()
