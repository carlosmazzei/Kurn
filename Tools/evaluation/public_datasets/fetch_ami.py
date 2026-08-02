#!/usr/bin/env python3
"""Fetch a small AMI Meeting Corpus subset for diarization-only evaluation.

AMI's own site distributes speaker annotation as multi-file NXT XML
(`words`/`segments`, cross-referenced by word IDs) -- fiddly to parse
correctly, and not something to get right unverified. `pyannote/AMI-diarization-setup`
(MIT-licensed) already ships ready-made RTTM derived from AMI's manual
"only_words" segmentation, keyed by meeting ID; that's what this script reads,
discovering meeting IDs from its `test` partition via the GitHub API rather
than hardcoding IDs that could drift if the repo's contents change.

Audio comes from the University of Edinburgh's AMI mirror
(`groups.inf.ed.ac.uk`) -- the Mix-Headset file (summed close-talk mics) every
AMI ASR/diarization recipe uses. Meetings run 30-60 minutes; both the audio
and its RTTM are clipped to the first `--clip-seconds` so the fetch and the
eval run stay bounded. Requires `ffmpeg` on PATH.

No WER reference is written here -- AMI's lexical transcript lives in the same
NXT XML this script deliberately avoids parsing blind. This corpus scores DER
only; `PublicEvaluationDataset` treats an item with a `.reference.rttm` but no
`.reference.txt` as DER-only, which is exactly this shape.

Can be imported as a module (`fetch(...)`) or run as a script.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

GITHUB_API = "https://api.github.com/repos/pyannote/AMI-diarization-setup/contents/only_words/rttms/test"
RAW_BASE = "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test"
AUDIO_BASE = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"


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

    written: list[str] = []
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
        written.append(meeting_id)

    if not written:
        raise SystemExit("ami: 0 meetings fetched successfully.")

    (out_dir / "dataset.json").write_text(
        json.dumps({"language": language, "corpus": corpus_name, "license": license_text}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"[fetch] ami: wrote {len(written)} meeting(s) to {out_dir}", flush=True)


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
