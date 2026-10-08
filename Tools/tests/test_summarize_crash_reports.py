"""Tests for Tools/summarize_crash_reports.py (run in the static-policy job)."""

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import summarize_crash_reports  # noqa: E402

HEADER = {"name": "Kurn", "timestamp": "2026-10-06 10:26:06.00 +0000", "bug_type": "309"}
BODY = {
    "procName": "Kurn",
    "termination": {"indicator": "Abort trap: 6"},
    "exception": {"type": "EXC_CRASH", "signal": "SIGABRT"},
    "asi": {"AudioToolbox": ["AURemoteIO: RPC timeout. Apparently deadlocked. Aborting now."]},
    "usedImages": [
        {"name": "libsystem_c.dylib"},
        {"name": "AudioToolbox"},
        {"name": "KurnTests"},
        {"name": "libdispatch.dylib"},
    ],
    "threads": [
        {"queue": "com.apple.main-thread", "frames": [{"imageIndex": 3, "symbol": "_dispatch_main"}]},
        {
            "name": "AURemoteIO::IOThread",
            "triggered": True,
            "frames": [
                {"imageIndex": 0, "symbol": "abort"},
                {"imageIndex": 1, "symbol": "AURemoteIO::Initialize"},
            ],
        },
        {
            "queue": "swift-testing",
            "frames": [
                {"imageIndex": 3, "symbol": "_dispatch_worker"},
                {"imageIndex": 2, "symbol": "SomeAudioTests.startsPlayback()"},
            ],
        },
    ],
}


def write_report(directory: str, name: str, header: dict, body: dict) -> str:
    path = os.path.join(directory, name)
    with open(path, "w") as handle:
        handle.write(json.dumps(header) + "\n" + json.dumps(body))
    return path


class SummaryTests(unittest.TestCase):
    def test_keeps_the_crashed_thread_and_threads_with_app_frames(self):
        lines = summarize_crash_reports.summarize(HEADER, BODY, max_frames=10)
        text = "\n".join(lines)
        self.assertIn("termination: Abort trap: 6", text)
        self.assertIn("message (AudioToolbox): AURemoteIO: RPC timeout", text)
        self.assertIn("-- thread 1 (crashed) AURemoteIO::IOThread", text)
        self.assertIn("AudioToolbox: AURemoteIO::Initialize", text)
        self.assertIn("-- thread 2 swift-testing", text)
        self.assertIn("KurnTests: SomeAudioTests.startsPlayback()", text)
        # A system-only thread says nothing about which test was running.
        self.assertNotIn("thread 0", text)
        # App threads show only their app frames.
        self.assertNotIn("_dispatch_worker", text)

    def test_truncates_long_threads(self):
        body = dict(BODY, threads=[{"triggered": True, "frames": [{"imageIndex": 0, "symbol": f"f{i}"} for i in range(5)]}])
        lines = summarize_crash_reports.summarize(HEADER, body, max_frames=2)
        self.assertIn("   … 3 more", lines)


class MainTests(unittest.TestCase):
    def run_main(self, *args):
        out = io.StringIO()
        with redirect_stdout(out):
            code = summarize_crash_reports.main(["summarize", *args])
        return code, out.getvalue()

    def test_prints_only_matching_parseable_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            write_report(directory, "Kurn-2026.ips", HEADER, BODY)
            write_report(directory, "Safari-2026.ips", dict(HEADER, name="Safari"), dict(BODY, procName="Safari"))
            with open(os.path.join(directory, "broken.ips"), "w") as handle:
                handle.write("not json")
            code, out = self.run_main(directory)
        self.assertEqual(code, 0)
        self.assertIn("== Kurn", out)
        self.assertNotIn("Safari", out)

    def test_says_so_when_there_is_nothing_to_print(self):
        with tempfile.TemporaryDirectory() as directory:
            code, out = self.run_main(directory)
        self.assertEqual(code, 0)
        self.assertIn("no crash reports matching", out)


if __name__ == "__main__":
    unittest.main()
