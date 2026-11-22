#!/usr/bin/env python3
"""Classify an AccessibilityBaselineUITests .xcresult bundle for CI summaries.

Distinguishes complete measurements (every expected test case and screen
audited with no execution or navigation errors) from partial measurements and
unmeasured runs, so an audit exception or setup failure is never reported as
`measured-with-findings`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any

EXPECTED_TEST_CASES = {
    "testCoreScreensDefaultSize",
    "testCoreScreensAX5",
    "testKnowledgeScreensDefaultSize",
    "testKnowledgeScreensAX5",
}
EXPECTED_SCREEN_COUNT = 24  # 12 audited screens x (Default, AX5)
FINDING_MARKER = "[A11Y_FINDING]"
MEASURED_PREFIX = "A11Y_MEASURED "


def _run_xcresulttool(args: list[str]) -> dict[str, Any]:
    result = subprocess.run(
        ["xcrun", "xcresulttool", *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def _walk_test_nodes(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            cases.append(node)
        children = node.get("children") or []
        if children:
            cases.extend(_walk_test_nodes(children))
    return cases


def _collect_failure_messages(node: dict[str, Any]) -> list[str]:
    messages: list[str] = []
    for child in node.get("children") or []:
        if child.get("nodeType") == "Failure Message":
            text = child.get("name") or child.get("details") or ""
            messages.append(text)
        messages.extend(_collect_failure_messages(child))
    return messages


def _collect_measured_screens(activities: list[dict[str, Any]], measured: set[str]) -> None:
    for activity in activities:
        title = activity.get("title") or ""
        if title.startswith(MEASURED_PREFIX):
            measured.add(title[len(MEASURED_PREFIX) :].strip())
        children = activity.get("childActivities") or []
        if children:
            _collect_measured_screens(children, measured)


def classify_bundle(xcresult_path: str, audit_outcome: str) -> str:
    if not os.path.isdir(xcresult_path) or audit_outcome not in {"success", "failure"}:
        return f"not-measured (audit step: {audit_outcome or 'skipped'})"

    try:
        tests_payload = _run_xcresulttool(
            ["get", "test-results", "tests", "--path", xcresult_path]
        )
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as exc:
        return f"not-measured (xcresulttool failed: {exc.__class__.__name__})"

    cases = _walk_test_nodes(tests_payload.get("testNodes") or [])
    ran_cases: set[str] = set()
    measured_screens: set[str] = set()
    findings = 0
    execution_errors = 0

    for case in cases:
        raw_name = (case.get("name") or "").removesuffix("()")
        if raw_name not in EXPECTED_TEST_CASES:
            continue
        case_result = case.get("result")
        if case_result not in {"Passed", "Failed"}:
            execution_errors += 1
            continue
        ran_cases.add(raw_name)

        messages = _collect_failure_messages(case)
        if case_result == "Failed" and not messages:
            execution_errors += 1
        for msg in messages:
            if FINDING_MARKER in msg:
                findings += 1
            else:
                execution_errors += 1

        test_id = case.get("nodeIdentifier") or case.get("nodeIdentifierURL")
        if not test_id:
            execution_errors += 1
            continue
        try:
            activities_payload = _run_xcresulttool(
                [
                    "get",
                    "test-results",
                    "activities",
                    "--path",
                    xcresult_path,
                    "--test-id",
                    test_id,
                ]
            )
        except (subprocess.CalledProcessError, json.JSONDecodeError, OSError):
            execution_errors += 1
            continue

        runs = activities_payload.get("testRuns") or []
        if isinstance(runs, dict):
            runs = [runs]
        for run in runs:
            _collect_measured_screens(run.get("activities") or [], measured_screens)

    measured_count = len(measured_screens)
    all_cases_ran = ran_cases == EXPECTED_TEST_CASES

    if all_cases_ran and measured_count == EXPECTED_SCREEN_COUNT and execution_errors == 0:
        if findings == 0:
            return f"measured-no-findings ({measured_count}/{EXPECTED_SCREEN_COUNT} screens)"
        return f"measured-with-findings ({measured_count}/{EXPECTED_SCREEN_COUNT} screens, {findings} findings)"

    if measured_count == 0:
        return (
            f"not-measured (0/{EXPECTED_SCREEN_COUNT} screens, "
            f"{len(ran_cases)}/{len(EXPECTED_TEST_CASES)} cases, {execution_errors} execution errors)"
        )

    return (
        f"partial-measurement ({measured_count}/{EXPECTED_SCREEN_COUNT} screens, "
        f"{len(ran_cases)}/{len(EXPECTED_TEST_CASES)} cases, {findings} findings, "
        f"{execution_errors} execution errors)"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcresult", required=True)
    parser.add_argument("--audit-outcome", default="")
    args = parser.parse_args()
    print(classify_bundle(args.xcresult, args.audit_outcome))
    return 0


if __name__ == "__main__":
    sys.exit(main())
