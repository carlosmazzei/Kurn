#!/usr/bin/env python3
"""Fetch a small AMI Meeting Corpus subset -- the only meeting-shaped material here.

Every other corpus in `manifest.json` is one speaker reading or answering into a
microphone. AMI is four people around a table, which is what the app actually
records, so this is the corpus whose numbers describe real use.

Speaker turns come from `pyannote/AMI-diarization-setup` (MIT-licensed), which
ships ready-made RTTM derived from AMI's manual "only_words" segmentation, keyed
by meeting ID. Meeting IDs are discovered from its `test` partition via the
GitHub API rather than hardcoded, which would drift if the repo's contents
change.

Audio comes from the University of Edinburgh's AMI mirror
(`groups.inf.ed.ac.uk`) -- the Mix-Headset file (summed close-talk mics) every
AMI ASR/diarization recipe uses. Meetings run 30-60 minutes; the audio, its
RTTM and its transcript are all clipped to the first `--clip-seconds` so the
fetch and the eval run stay bounded. Requires `ffmpeg` on PATH.

The lexical transcript comes from AMI's own manual annotation zip, off the same
Edinburgh host as the audio. Only `words/*.words.xml` is read, and only for the
words themselves: each `<w>` carries its own `starttime`, so a time-ordered
reference needs no speaker mapping and none of the `segments`/`dialogue-acts`
cross-referencing that made the NXT format not worth parsing blind. That makes
AMI the one corpus scored on **both** WER and DER -- the only place the
pipeline's real output, text attributed to a speaker, is measured end to end.

The transcript is strictly optional. Any failure -- host down, zip layout
changed, parse producing something implausible -- logs and leaves the meeting
DER-only, which is exactly what it was before and a shape
`PublicEvaluationDataset` already understands. A missing WER reference costs one
metric; a silently wrong one would be worse than none.

Can be imported as a module (`fetch(...)`) or run as a script.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

GITHUB_API = "https://api.github.com/repos/pyannote/AMI-diarization-setup/contents/only_words/rttms/test"
RAW_BASE = "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test"
AUDIO_BASE = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
ANNOTATIONS_URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"

# `words/<meeting>.<agent>.words.xml`, one file per speaker slot in a meeting.
WORDS_MEMBER = re.compile(r"(?:^|/)words/(?P<meeting>[^/.]+)\.(?P<agent>[^/.]+)\.words\.xml$")

# A transcript this far outside a plausible speaking rate did not parse correctly.
# Conversational English runs ~2-3 words/second of speech; the bounds are wide
# enough that only a structural mistake trips them.
MIN_WORDS_PER_SPEECH_SECOND = 0.3
MAX_WORDS_PER_SPEECH_SECOND = 8.0
MIN_WORDS = 20


def fetch_json(url: str, timeout: int = 60):
    request = urllib.request.Request(url, headers={"User-Agent": "kurn-eval-fetch"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def fetch_text(url: str, timeout: int = 60) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "kurn-eval-fetch"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8")


def clip_rttm(text: str, clip_seconds: float) -> str:
    """Keep only turns that start before `clip_seconds`, truncated to it."""
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            continue
        start, duration = float(fields[3]), float(fields[4])
        if start >= clip_seconds:
            continue
        end = min(start + duration, clip_seconds)
        fields[3] = f"{start:.3f}"
        fields[4] = f"{end - start:.3f}"
        rows.append(" ".join(fields))
    return "\n".join(rows) + ("\n" if rows else "")


def speech_seconds(rttm_text: str) -> float:
    """Total annotated speech in an RTTM, overlap counted once per turn."""
    total = 0.0
    for line in rttm_text.splitlines():
        fields = line.split()
        if len(fields) >= 8 and fields[0] == "SPEAKER":
            total += float(fields[4])
    return total


def words_from_xml(data: bytes) -> list[tuple[float, str]]:
    """`(starttime, word)` for every timed, non-punctuation `<w>` in one file.

    Everything else in the file -- `<vocalsound>`, `<gap>`, `<disfmarker>` --
    is not lexical content and is skipped by only ever looking at `w` tags.
    Untimed words exist (a handful per meeting) and are dropped rather than
    guessed at: without a time they cannot be ordered against other speakers.
    """
    words: list[tuple[float, str]] = []
    root = ET.fromstring(data)
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] != "w":
            continue
        if element.get("punc") == "true":
            continue
        start = element.get("starttime")
        text = (element.text or "").strip()
        if start is None or not text:
            continue
        try:
            words.append((float(start), text))
        except ValueError:
            continue
    return words


def download_annotations(destination: Path) -> zipfile.ZipFile | None:
    """AMI's manual annotation zip, or `None` if it cannot be had.

    Downloaded once per fetch rather than per meeting -- it carries every
    meeting's words, and it is the same host the audio comes from.
    """
    print(f"[fetch] ami: downloading manual annotations {ANNOTATIONS_URL}", flush=True)
    try:
        urllib.request.urlretrieve(ANNOTATIONS_URL, destination)
        return zipfile.ZipFile(destination)
    except Exception as error:  # noqa: BLE001 - any failure means "no transcript"
        print(
            f"[fetch] ami: could not download/open the manual annotations ({error}); "
            "meetings will be scored on DER only",
            file=sys.stderr,
            flush=True,
        )
        return None


def index_words_members(archive: zipfile.ZipFile) -> dict[str, list[str]]:
    """meeting id -> its `words/*.words.xml` members."""
    index: dict[str, list[str]] = {}
    for name in archive.namelist():
        match = WORDS_MEMBER.search(name)
        if match:
            index.setdefault(match["meeting"], []).append(name)
    return index


def transcript_for(
    archive: zipfile.ZipFile,
    members: list[str],
    meeting_id: str,
    clip_seconds: float,
    rttm_speech: float,
) -> str | None:
    """Time-ordered words of one meeting's clip window, or `None` if implausible.

    Merging every speaker's words into one time-ordered stream is exactly what a
    WER reference needs: `WordErrorRate` scores the text the pipeline produced,
    not who said it, so no speaker mapping is involved and none can go wrong.
    """
    words: list[tuple[float, str]] = []
    for member in members:
        try:
            words.extend(words_from_xml(archive.read(member)))
        except (ET.ParseError, KeyError) as error:
            print(f"[fetch] ami: {meeting_id}: could not parse {member} ({error})", file=sys.stderr, flush=True)
            return None

    words = sorted((start, text) for start, text in words if start < clip_seconds)
    if len(words) < MIN_WORDS:
        print(
            f"[fetch] ami: {meeting_id}: only {len(words)} word(s) in the first "
            f"{clip_seconds}s, leaving it DER-only",
            file=sys.stderr,
            flush=True,
        )
        return None

    rate = len(words) / rttm_speech if rttm_speech > 0 else 0.0
    if not MIN_WORDS_PER_SPEECH_SECOND <= rate <= MAX_WORDS_PER_SPEECH_SECOND:
        print(
            f"[fetch] ami: {meeting_id}: {len(words)} words over {rttm_speech:.1f}s of annotated "
            f"speech is {rate:.2f} words/s, outside the plausible range -- the annotation layout "
            "has probably changed. Leaving it DER-only rather than scoring against a bad reference.",
            file=sys.stderr,
            flush=True,
        )
        return None

    return " ".join(text for _, text in words) + "\n"


def fetch(entry: dict, out_dir: Path) -> None:
    """Fetch one AMI corpus entry into `out_dir`."""
    out_dir.mkdir(parents=True, exist_ok=True)

    meeting_count = int(entry.get("meeting_count", 2))
    clip_seconds = float(entry.get("clip_seconds", 300))
    language = entry["language"]
    license_text = entry.get("license", "")
    corpus_name = entry.get("corpus_name", "AMI Meeting Corpus (Mix-Headset)")

    print(f"[fetch] ami: listing {GITHUB_API}", flush=True)
    try:
        entries = fetch_json(GITHUB_API)
    except Exception as error:
        raise SystemExit(
            f"ami: could not list pyannote/AMI-diarization-setup's test RTTMs ({error}).\n"
            "The repo may have moved or renamed only_words/rttms/test -- check GITHUB_API in this script."
        ) from error

    meeting_ids = sorted(
        entry["name"][: -len(".rttm")] for entry in entries if entry["name"].endswith(".rttm")
    )[:meeting_count]

    if not meeting_ids:
        raise SystemExit(
            "ami: found no .rttm files under pyannote/AMI-diarization-setup's only_words/rttms/test. "
            "The repo layout may have changed -- check GITHUB_API/RAW_BASE in this script."
        )

    annotations_path = Path(tempfile.gettempdir()) / "ami_public_manual.zip"
    archive = download_annotations(annotations_path)
    words_index = index_words_members(archive) if archive else {}

    written: list[str] = []
    scored_wer = 0
    for meeting_id in meeting_ids:
        print(f"[fetch] ami: {meeting_id}", flush=True)
        try:
            rttm = fetch_text(f"{RAW_BASE}/{meeting_id}.rttm")
        except Exception as error:
            print(f"[fetch] ami: {meeting_id}: could not download RTTM ({error}), skipping", file=sys.stderr, flush=True)
            continue

        clipped_rttm = clip_rttm(rttm, clip_seconds)
        if not clipped_rttm.strip():
            print(f"[fetch] ami: {meeting_id} has no speech in the first {clip_seconds}s, skipping", file=sys.stderr, flush=True)
            continue

        audio_url = f"{AUDIO_BASE}/{meeting_id}/audio/{meeting_id}.Mix-Headset.wav"
        raw_path = out_dir / f"{meeting_id}.full.wav"
        try:
            urllib.request.urlretrieve(audio_url, raw_path)
        except Exception as error:
            print(f"[fetch] ami: {meeting_id}: could not download {audio_url} ({error}), skipping", file=sys.stderr, flush=True)
            continue

        clipped_path = out_dir / f"{meeting_id}.audio.wav"
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-i", str(raw_path), "-t", str(clip_seconds), str(clipped_path)],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as error:
            print(f"[fetch] ami: {meeting_id}: ffmpeg failed ({error}), skipping", file=sys.stderr, flush=True)
            raw_path.unlink(missing_ok=True)
            continue
        finally:
            if raw_path.exists():
                raw_path.unlink(missing_ok=True)

        (out_dir / f"{meeting_id}.reference.rttm").write_text(clipped_rttm, encoding="utf-8")

        if archive is not None and meeting_id in words_index:
            transcript = transcript_for(
                archive,
                words_index[meeting_id],
                meeting_id,
                clip_seconds,
                speech_seconds(clipped_rttm),
            )
            if transcript:
                (out_dir / f"{meeting_id}.reference.txt").write_text(transcript, encoding="utf-8")
                scored_wer += 1
        elif archive is not None:
            print(
                f"[fetch] ami: {meeting_id}: no words/*.words.xml in the annotation zip, leaving it DER-only",
                file=sys.stderr,
                flush=True,
            )

        written.append(meeting_id)

    if archive is not None:
        archive.close()
        annotations_path.unlink(missing_ok=True)

    if not written:
        raise SystemExit("ami: 0 meetings fetched successfully.")

    (out_dir / "dataset.json").write_text(
        json.dumps({"language": language, "corpus": corpus_name, "license": license_text}, indent=2) + "\n",
        encoding="utf-8",
    )
    scoring = f"{scored_wer} with WER+DER, {len(written) - scored_wer} DER-only"
    print(f"[fetch] ami: wrote {len(written)} meeting(s) to {out_dir} ({scoring})", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--meeting-count", type=int, default=2)
    parser.add_argument("--clip-seconds", type=float, default=300)
    parser.add_argument("--language", default="english")
    parser.add_argument("--license", default="CC BY 4.0 (AMI Corpus); MIT (RTTM setup)")
    parser.add_argument("--corpus-name", default="AMI Meeting Corpus (Mix-Headset)")
    args = parser.parse_args()

    entry = {
        "language": args.language,
        "license": args.license,
        "corpus_name": args.corpus_name,
        "meeting_count": args.meeting_count,
        "clip_seconds": args.clip_seconds,
    }
    fetch(entry, args.out)


if __name__ == "__main__":
    sys.exit(main())
