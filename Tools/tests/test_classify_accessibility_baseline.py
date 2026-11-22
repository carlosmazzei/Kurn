"""Unit tests for Tools/classify_accessibility_baseline.py using xcresulttool payloads."""

from __future__ import annotations

import os
import tempfile
import unittest
from unittest import mock

from Tools import classify_accessibility_baseline as mod


CORE_SCREENS = [
    "MeetingsList",
    "FolderFormView",
    "SettingsView",
    "MeetingDetail.recordings",
    "MeetingDetail.transcript",
    "MeetingDetail.summary",
    "MeetingDetail.chat",
    "RecorderView",
]
KNOWLEDGE_SCREENS = [
    "KnowledgeHome+ExportToolbar",
    "KnowledgeEntityPage+Narrative",
    "MeetingsList+KnowledgeOn",
    "MeetingDetail.knowledge",
]
EXPECTED_SCREENS_BY_CASE = {
    "testCoreScreensDefaultSize": [f"{s} (Default)" for s in CORE_SCREENS],
    "testCoreScreensAX5": [f"{s} (AX5)" for s in CORE_SCREENS],
    "testKnowledgeScreensDefaultSize": [f"{s} (Default)" for s in KNOWLEDGE_SCREENS],
    "testKnowledgeScreensAX5": [f"{s} (AX5)" for s in KNOWLEDGE_SCREENS],
}


def _tests_payload(case_specs: dict[str, tuple[str, list[str]]]) -> dict:
    """Builds a payload matching `xcresulttool get test-results tests` schema 0.4.0."""
    test_cases = []
    for name, (result, failures) in case_specs.items():
        node_id = f"KurnUITests/AccessibilityBaselineUITests/{name}()"
        test_cases.append(
            {
                "nodeType": "Test Case",
                "nodeIdentifier": node_id,
                "nodeIdentifierURL": f"test://com.apple.xcode/{node_id}",
                "name": f"{name}()",
                "result": result,
                "children": [
                    {"nodeType": "Failure Message", "name": message, "details": message}
                    for message in failures
                ],
            }
        )
    return {
        "devices": [{"deviceId": "sim-1", "deviceName": "iPhone 17"}],
        "testPlanConfigurations": [{"configurationId": "1", "configurationName": "Default"}],
        "testNodes": [
            {
                "nodeType": "Test Plan",
                "name": "Kurn",
                "result": "Failed",
                "children": [
                    {
                        "nodeType": "UI test bundle",
                        "name": "KurnUITests",
                        "children": [
                            {
                                "nodeType": "Test Suite",
                                "name": "AccessibilityBaselineUITests",
                                "children": test_cases,
                            }
                        ],
                    }
                ],
            }
        ],
    }


def _activities_payload(test_id: str, measured_screens: list[str], *, single_run_dict: bool = False) -> dict:
    """Builds a payload matching `xcresulttool get test-results activities` schema 0.4.0."""
    activities = [
        {
            "title": f"Audit {screen}",
            "activityType": "com.apple.dt.xctest.activity-type.userCreated",
            "isAssociatedWithFailure": False,
            "childActivities": [
                {
                    "title": f"A11Y_MEASURED {screen}",
                    "activityType": "com.apple.dt.xctest.activity-type.userCreated",
                    "isAssociatedWithFailure": False,
                }
            ],
        }
        for screen in measured_screens
    ]
    run_obj = {"activities": activities}
    return {
        "testIdentifier": test_id,
        "testName": test_id.split("/")[-1],
        "testRuns": run_obj if single_run_dict else [run_obj],
    }


class ClassifyAccessibilityBaselineTests(unittest.TestCase):
    def _mock_runner(
        self,
        case_specs: dict[str, tuple[str, list[str]]],
        measured_by_case: dict[str, list[str]],
        *,
        single_run_dict: bool = False,
    ):
        tests_json = _tests_payload(case_specs)

        def _fake(args: list[str]) -> dict:
            if args[:3] == ["get", "test-results", "tests"]:
                return tests_json
            if args[:3] == ["get", "test-results", "activities"]:
                test_id = args[args.index("--test-id") + 1]
                case_name = test_id.split("/")[-1].removesuffix("()")
                return _activities_payload(
                    test_id,
                    measured_by_case.get(case_name, []),
                    single_run_dict=single_run_dict,
                )
            raise AssertionError(f"Unexpected xcresulttool args: {args}")

        return _fake

    def test_missing_bundle_reports_not_measured(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = os.path.join(directory, "TestResults.xcresult")
            self.assertEqual(
                mod.classify_bundle(missing, "skipped"),
                "not-measured (audit step: skipped)",
            )

    def test_complete_measurement_with_zero_findings(self):
        specs = {name: ("Passed", []) for name in EXPECTED_SCREENS_BY_CASE}
        with tempfile.TemporaryDirectory() as bundle, mock.patch.object(
            mod,
            "_run_xcresulttool",
            side_effect=self._mock_runner(specs, EXPECTED_SCREENS_BY_CASE, single_run_dict=True),
        ):
            self.assertEqual(
                mod.classify_bundle(bundle, "success"),
                "measured-no-findings (24/24 screens)",
            )

    def test_complete_measurement_with_only_accessibility_findings(self):
        specs = {name: ("Passed", []) for name in EXPECTED_SCREENS_BY_CASE}
        specs["testCoreScreensAX5"] = (
            "Failed",
            [
                "[A11Y_FINDING] [MeetingsList | AX5] [contrast] Contrast nearly passed",
                "[A11Y_FINDING] [RecorderView | AX5] [hitRegion] Hit region too small",
            ],
        )
        with tempfile.TemporaryDirectory() as bundle, mock.patch.object(
            mod,
            "_run_xcresulttool",
            side_effect=self._mock_runner(specs, EXPECTED_SCREENS_BY_CASE),
        ):
            self.assertEqual(
                mod.classify_bundle(bundle, "failure"),
                "measured-with-findings (24/24 screens, 2 findings)",
            )

    def test_audit_exception_or_navigation_failure_reports_partial_measurement(self):
        specs = {name: ("Passed", []) for name in EXPECTED_SCREENS_BY_CASE}
        specs["testCoreScreensAX5"] = (
            "Failed",
            [
                "[A11Y_FINDING] [MeetingsList | AX5] [contrast] Low contrast",
                "[A11Y_AUDIT_ERROR] [RecorderView | AX5] Audit threw error: XCUITestError",
            ],
        )
        partial_screens = dict(EXPECTED_SCREENS_BY_CASE)
        partial_screens["testCoreScreensAX5"] = EXPECTED_SCREENS_BY_CASE["testCoreScreensAX5"][:-1]

        with tempfile.TemporaryDirectory() as bundle, mock.patch.object(
            mod,
            "_run_xcresulttool",
            side_effect=self._mock_runner(specs, partial_screens),
        ):
            self.assertEqual(
                mod.classify_bundle(bundle, "failure"),
                "partial-measurement (23/24 screens, 4/4 cases, 1 findings, 1 execution errors)",
            )

    def test_all_cases_failing_before_any_audit_reports_not_measured(self):
        specs = {
            name: ("Failed", ["XCTAssertTrue failed - Missing meetings.record button"])
            for name in EXPECTED_SCREENS_BY_CASE
        }
        empty_screens = {name: [] for name in EXPECTED_SCREENS_BY_CASE}

        with tempfile.TemporaryDirectory() as bundle, mock.patch.object(
            mod,
            "_run_xcresulttool",
            side_effect=self._mock_runner(specs, empty_screens),
        ):
            self.assertEqual(
                mod.classify_bundle(bundle, "failure"),
                "not-measured (0/24 screens, 4/4 cases, 4 execution errors)",
            )


if __name__ == "__main__":
    unittest.main()
