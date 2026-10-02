"""Tests for Tools/lcov.py and Tools/coverage_gate.py (run in the static-policy job).

    python3 -m unittest discover -s Tools/tests -t .
"""

import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import coverage_gate  # noqa: E402
import lcov  # noqa: E402

SCOPE = {
    "include": ["Kurn/", "Packages/KurnCore/Sources/"],
    "exclude": [
        {"pattern": "Kurn/Views/**", "reason": "views"},
        {"pattern": "Kurn/ContentView.swift", "reason": "root view"},
    ],
}


def tracefile(records: dict) -> str:
    """`{absolute path: {line: hits}}` -> lcov text."""
    out = ["TN:"]
    for path, lines in records.items():
        out.append(f"SF:{path}")
        out += [f"DA:{line},{count}" for line, count in lines.items()]
        out.append("end_of_record")
    return "\n".join(out) + "\n"


class Workspace:
    """A temporary checkout with a few source files, tracefiles and config."""

    def __init__(self, test: unittest.TestCase, floor: dict | None = None):
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        self.root = self.dir.name
        for rel in ["Kurn/Services/A.swift", "Kurn/Models/B.swift", "Kurn/Views/V.swift",
                    "Packages/KurnCore/Sources/KurnCore/C.swift"]:
            path = os.path.join(self.root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w").close()
        self.scope = self.write("scope.json", SCOPE)
        self.floor = self.write("floor.json", floor or {"target": 80.0, "tolerance": 0.5,
                                                        "total": None, "layers": {}})

    def write(self, name: str, data) -> str:
        path = os.path.join(self.root, name)
        with open(path, "w") as handle:
            handle.write(data if isinstance(data, str) else json.dumps(data))
        return path

    def run(self, *files: str, extra: tuple = ()) -> tuple[int, str]:
        out = io.StringIO()
        code = coverage_gate.main(["--root", self.root, "--scope", self.scope, "--floor", self.floor,
                                   *extra, *files], out=out)
        return code, out.getvalue()


class RelativeTests(unittest.TestCase):
    def test_runner_layouts_from_both_platforms_resolve_to_the_same_path(self):
        ws = Workspace(self)
        mac = "/Users/runner/work/Kurn/Kurn/Kurn/Services/A.swift"
        linux = "/home/runner/work/Kurn/Kurn/Packages/KurnCore/Sources/KurnCore/C.swift"
        self.assertEqual(lcov.relative(mac, ws.root), "Kurn/Services/A.swift")
        self.assertEqual(lcov.relative(linux, ws.root), "Packages/KurnCore/Sources/KurnCore/C.swift")
        self.assertEqual(lcov.relative(mac, None), "Kurn/Services/A.swift")

    def test_hits_are_unioned_across_tracefiles(self):
        ws = Workspace(self)
        a = ws.write("a.lcov", tracefile({"/x/Kurn/Kurn/Kurn/Services/A.swift": {1: 0, 2: 3}}))
        b = ws.write("b.lcov", tracefile({"/y/Kurn/Kurn/Kurn/Services/A.swift": {1: 1, 2: 0}}))
        hits: dict = {}
        lcov.parse(a, hits, ws.root)
        lcov.parse(b, hits, ws.root)
        self.assertEqual(lcov.per_file(hits)["Kurn/Services/A.swift"], [2, 2])


class ScopeTests(unittest.TestCase):
    def test_include_roots_and_exclusions(self):
        scope = lcov.Scope(SCOPE["include"], SCOPE["exclude"])
        self.assertTrue(scope.contains("Kurn/Services/A.swift"))
        self.assertTrue(scope.contains("Kurn/AppComposition.swift"))
        self.assertTrue(scope.contains("Packages/KurnCore/Sources/KurnCore/C.swift"))
        self.assertFalse(scope.contains("Kurn/Views/Settings/X.swift"))
        self.assertFalse(scope.contains("Kurn/ContentView.swift"))
        self.assertFalse(scope.contains("KurnWatch/W.swift"))
        self.assertFalse(scope.contains("Packages/KurnCore/Tests/T.swift"))

    def test_repository_scope_file_is_valid_and_every_exclusion_has_a_reason(self):
        scope = lcov.Scope.load()
        self.assertTrue(scope.include)
        for entry in scope.exclude:
            self.assertTrue(entry.get("reason", "").strip(), entry["pattern"])

    def test_repository_floor_file_is_valid(self):
        with open(coverage_gate.FLOOR_FILE) as handle:
            floor = json.load(handle)
        self.assertEqual(floor["target"], 80.0)
        self.assertIn("layers", floor)
        self.assertGreaterEqual(floor["tolerance"], 1.0, "below the measured run-to-run noise the gate flakes")


class FloorTests(unittest.TestCase):
    def records(self, ws: Workspace, services_hit: int) -> str:
        services = {line: (1 if line <= services_hit else 0) for line in range(1, 11)}
        return ws.write("r.lcov", tracefile({
            f"{ws.root}/Kurn/Services/A.swift": services,
            f"{ws.root}/Kurn/Models/B.swift": {1: 1, 2: 1},
            f"{ws.root}/Kurn/Views/V.swift": {line: 0 for line in range(1, 100)},
        }))

    def test_bootstrap_floor_reports_and_passes(self):
        ws = Workspace(self)
        code, out = self.run_gate(ws, self.records(ws, 5))
        self.assertEqual(code, 0)
        self.assertIn("No floor recorded yet", out)
        self.assertIn("58.3%", out)  # 7 of 12 in-scope lines; the view's 99 are not counted

    def test_write_floor_rounds_down_and_then_holds(self):
        ws = Workspace(self)
        report = self.records(ws, 5)
        self.assertEqual(ws.run(report, extra=("--write-floor",))[0], 0)
        with open(ws.floor) as handle:
            floor = json.load(handle)
        self.assertEqual(floor["total"], 58.3)
        self.assertEqual(floor["layers"], {"Kurn/Models": 100.0, "Kurn/Services": 50.0})
        self.assertEqual(ws.run(report)[0], 0)

    def test_write_floor_never_lowers_a_recorded_value(self):
        ws = Workspace(self, {"target": 80.0, "tolerance": 1.0, "total": 90.0,
                              "layers": {"Kurn/Services": 70.0, "Kurn/Models": 10.0}})
        report = self.records(ws, 5)
        self.assertEqual(ws.run(report, extra=("--write-floor",))[0], 0)
        with open(ws.floor) as handle:
            floor = json.load(handle)
        self.assertEqual(floor["total"], 90.0)
        self.assertEqual(floor["layers"], {"Kurn/Models": 100.0, "Kurn/Services": 70.0})

    def test_drop_below_floor_fails(self):
        ws = Workspace(self, {"target": 80.0, "tolerance": 0.5, "total": 70.0,
                        "layers": {"Kurn/Services": 60.0}})
        code, out = self.run_gate(ws, self.records(ws, 5))
        self.assertEqual(code, 1)
        self.assertIn("below the floor", out)
        self.assertIn("`Kurn/Services` coverage 50.0% is below its floor 60.0%", out)

    def test_tolerance_absorbs_small_noise(self):
        ws = Workspace(self, {"target": 80.0, "tolerance": 0.5, "total": 58.6, "layers": {}})
        self.assertEqual(self.run_gate(ws, self.records(ws, 5))[0], 0)

    def test_missing_report_fails(self):
        ws = Workspace(self)
        empty = ws.write("empty.lcov", "")
        self.assertEqual(ws.run(empty)[0], 1)

    @staticmethod
    def run_gate(ws: Workspace, report: str) -> tuple[int, str]:
        return ws.run(report)


class PatchTests(unittest.TestCase):
    DIFF = """diff --git a/Kurn/Services/A.swift b/Kurn/Services/A.swift
--- a/Kurn/Services/A.swift
+++ b/Kurn/Services/A.swift
@@ -1,0 +2,4 @@
+x
+x
+x
+x
@@ -20 +30 @@
+x
diff --git a/Kurn/Views/V.swift b/Kurn/Views/V.swift
--- a/Kurn/Views/V.swift
+++ b/Kurn/Views/V.swift
@@ -0,0 +1,3 @@
+x
diff --git a/Old.swift b/Old.swift
--- a/Old.swift
+++ /dev/null
@@ -1,2 +0,0 @@
-x
"""

    def test_added_lines_parses_hunks(self):
        added = coverage_gate.added_lines(self.DIFF)
        self.assertEqual(added["Kurn/Services/A.swift"], {2, 3, 4, 5, 30})
        self.assertEqual(added["Kurn/Views/V.swift"], {1, 2, 3})
        self.assertNotIn("Old.swift", added)

    def check(self, hits_by_line: dict) -> tuple[list, str]:
        hits = {("Kurn/Services/A.swift", line): count for line, count in hits_by_line.items()}
        hits[("Kurn/Views/V.swift", 1)] = 0
        scope = lcov.Scope(SCOPE["include"], SCOPE["exclude"])
        out = io.StringIO()
        failures = coverage_gate.check_patch(hits, scope, coverage_gate.added_lines(self.DIFF), 80.0, out)
        return failures, out.getvalue()

    def test_uncovered_new_lines_fail(self):
        # Lines 2-5 executable, only 2 hit; 30 is not executable (comment) so it does not count.
        failures, out = self.check({2: 1, 3: 0, 4: 0, 5: 0})
        self.assertEqual(len(failures), 1)
        self.assertIn("25.0%", failures[0])
        self.assertIn("3-5", out)

    def test_covered_new_lines_pass_and_views_are_ignored(self):
        failures, out = self.check({2: 1, 3: 1, 4: 1, 5: 1})
        self.assertEqual(failures, [])
        self.assertNotIn("Views", out)

    def test_no_executable_changes_pass(self):
        failures, out = self.check({50: 0})
        self.assertEqual(failures, [])
        self.assertIn("No executable in-scope lines changed", out)

    def test_ranges(self):
        self.assertEqual(coverage_gate.ranges([5, 1, 2, 3, 9]), "1-3, 5, 9")


if __name__ == "__main__":
    unittest.main()
