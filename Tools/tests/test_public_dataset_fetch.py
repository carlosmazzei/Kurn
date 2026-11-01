import io
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

FETCH_DIR = Path(__file__).resolve().parents[2] / "Tools/evaluation/public_datasets"
sys.path.insert(0, str(FETCH_DIR))

import fetch_all  # noqa: E402
import fetch_ami  # noqa: E402


class FakeResponse(io.BytesIO):
    def __init__(self, body: bytes, status: int = 200, length: int | None = None):
        super().__init__(body)
        self.status = status
        self.headers = {"Content-Length": str(len(body) if length is None else length)}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def http_error(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError("https://example.invalid", code, "error", {}, None)


class ScriptedOpener:
    """Plays back one outcome per call and records the Range header sent."""

    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.ranges: list[str | None] = []

    def __call__(self, request, timeout=None):
        self.ranges.append(request.get_header("Range"))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.destination = self.directory / "meeting.wav"

    def download(self, opener, attempts=4):
        fetch_ami.download(
            "https://example.invalid/meeting.wav",
            self.destination,
            attempts=attempts,
            backoff=(0,),
            opener=opener,
            sleep=lambda _: None,
        )

    def test_retries_a_throttled_403(self):
        opener = ScriptedOpener([http_error(403), http_error(403), FakeResponse(b"audio")])
        self.download(opener)
        self.assertEqual(self.destination.read_bytes(), b"audio")
        self.assertEqual(len(opener.ranges), 3)

    def test_resumes_a_truncated_transfer_with_a_range_request(self):
        # The server announces 10 bytes but the connection drops after 4.
        opener = ScriptedOpener([
            FakeResponse(b"abcd", length=10),
            FakeResponse(b"efghij", status=206),
        ])
        self.download(opener)
        self.assertEqual(self.destination.read_bytes(), b"abcdefghij")
        self.assertEqual(opener.ranges, [None, "bytes=4-"])

    def test_restarts_when_the_server_ignores_the_range(self):
        opener = ScriptedOpener([
            FakeResponse(b"abcd", length=10),
            FakeResponse(b"0123456789", status=200),
        ])
        self.download(opener)
        self.assertEqual(self.destination.read_bytes(), b"0123456789")

    def test_gives_up_on_a_permanent_error_without_retrying(self):
        opener = ScriptedOpener([http_error(404), FakeResponse(b"never")])
        with self.assertRaises(urllib.error.HTTPError):
            self.download(opener)
        self.assertEqual(len(opener.ranges), 1)
        self.assertFalse(self.destination.exists())

    def test_leaves_no_partial_file_when_every_attempt_fails(self):
        opener = ScriptedOpener([FakeResponse(b"ab", length=10), http_error(403)])
        with self.assertRaises(urllib.error.HTTPError):
            self.download(opener, attempts=2)
        self.assertEqual(list(self.directory.iterdir()), [])


class CacheReuseTests(unittest.TestCase):
    def test_a_meeting_needs_both_its_clip_and_its_rttm(self):
        directory = Path(tempfile.mkdtemp())
        self.assertFalse(fetch_ami.is_cached(directory, "ES2004a"))
        (directory / "ES2004a.audio.wav").write_bytes(b"audio")
        self.assertFalse(fetch_ami.is_cached(directory, "ES2004a"))
        (directory / "ES2004a.reference.rttm").write_text("SPEAKER ...\n", encoding="utf-8")
        self.assertTrue(fetch_ami.is_cached(directory, "ES2004a"))
        (directory / "ES2004a.audio.wav").write_bytes(b"")
        self.assertFalse(fetch_ami.is_cached(directory, "ES2004a"))


class FetchFailurePolicyTests(unittest.TestCase):
    def test_one_failed_corpus_does_not_fail_the_others(self):
        self.assertFalse(fetch_all.fetch_should_fail(["ami-en", "voxconverse-en"], ["ami-en"]))
        self.assertFalse(fetch_all.fetch_should_fail(["ami-en"], []))

    def test_fails_when_nothing_asked_for_could_be_fetched(self):
        self.assertTrue(fetch_all.fetch_should_fail(["ami-en"], ["ami-en"]))
        # A gated corpus skipped for want of a token is never attempted.
        self.assertTrue(fetch_all.fetch_should_fail([], ["common-voice-pt"]))


if __name__ == "__main__":
    unittest.main()
