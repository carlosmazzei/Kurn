#!/usr/bin/env python3
"""Fetch a small subset of a Hugging Face speaker-diarization dataset.

The counterpart to `fetch_huggingface_audio_dataset.py`: that one writes
`<name>.reference.txt` for WER, this one writes `<name>.reference.rttm` for DER.

It targets the layout the `diarizers-community` datasets share, produced by
`diarizers`' own `SpeakerDiarizationDataset(...).construct_dataset()` from RTTM:

    audio             the recording
    timestamps_start  list[float], one per turn
    timestamps_end    list[float], one per turn
    speakers          list[str],   one per turn

Because that shape is a convention rather than a spec, every column is checked
before anything is written and a mismatch fails loudly with the columns it
actually found. A diarization reference that is quietly misaligned would score
as a plausible DER and be indistinguishable from a real result.

One kind covers every corpus published in that layout -- VoxConverse, AMI,
CallHome, Simsamu -- so adding one is a `manifest.json` entry rather than a new
script. Note that some of them (CallHome in particular) are LDC-licensed
underneath: check the dataset's terms before enabling one.

`clip_seconds` trims each recording, and its turns, the way the AMI fetch does.
Diarization corpora run to tens of minutes per file and the eval cost is
audio-seconds x configurations, so leaving them full-length is rarely what you
want. Requires `ffmpeg` on PATH when set.

Can be imported as a module (`fetch(...)`) or run as a script.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from fetch_huggingface_audio_dataset import extract_audio_bytes, slugify

REQUIRED_COLUMNS = ("timestamps_start", "timestamps_end", "speakers")


def rttm_lines(
    name: str,
    starts: list[float],
    ends: list[float],
    speakers: list[str],
    clip_seconds: float | None,
) -> str:
    """Turns as RTTM, in the format `RTTM.parse` reads.

    Speaker labels are passed through untouched but for whitespace: the harness
    scores under the label mapping that maximises agreement, so their spelling
    never matters -- but a space inside one would shift every later field.
    """
    rows = []
    for start, end, speaker in zip(starts, ends, speakers):
        start, end = float(start), float(end)
        if clip_seconds is not None:
            if start >= clip_seconds:
                continue
            end = min(end, clip_seconds)
        duration = end - start
        if duration <= 0:
            continue
        label = "_".join(str(speaker).split()) or "speaker"
        rows.append(
            f"SPEAKER {name} 1 {start:.3f} {duration:.3f} <NA> <NA> {label} <NA> <NA>"
        )
    return "\n".join(rows) + ("\n" if rows else "")


def clip_audio(source: Path, destination: Path, clip_seconds: float) -> bool:
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(source), "-t", str(clip_seconds), str(destination)],
            check=True,
            capture_output=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        print(f"[fetch] ffmpeg failed on {source.name} ({error})", file=sys.stderr, flush=True)
        return False


def fetch(entry: dict, out_dir: Path, token: str | None = None) -> None:
    """Fetch one diarization corpus entry into `out_dir`."""
    try:
        from datasets import Audio, load_dataset
    except ImportError as error:
        raise SystemExit(
            "missing dependency: pip install datasets huggingface_hub "
            "(see Tools/evaluation/public_datasets/README.md)"
        ) from error

    out_dir.mkdir(parents=True, exist_ok=True)

    print(
        f"[fetch] {entry['id']}: loading {entry['hf_dataset']} ({entry.get('hf_config')}) split={entry['hf_split']}",
        flush=True,
    )

    dataset = load_dataset(
        entry["hf_dataset"],
        entry.get("hf_config"),
        split=entry["hf_split"],
        streaming=True,
        token=token,
        trust_remote_code=bool(entry.get("trust_remote_code", False)),
    )
    audio_column = entry.get("audio_column", "audio")
    dataset = dataset.cast_column(audio_column, Audio(decode=False))

    sample_count = int(entry["sample_count"])
    clip_seconds = entry.get("clip_seconds")
    clip_seconds = float(clip_seconds) if clip_seconds else None

    written: list[str] = []
    row_count = 0
    for row_count, row in enumerate(dataset, start=1):
        if len(written) >= sample_count:
            break

        missing = [column for column in REQUIRED_COLUMNS if column not in row]
        if missing:
            raise SystemExit(
                f"{entry['id']}: row is missing {', '.join(missing)}.\n"
                f"Found columns: {', '.join(sorted(row))}.\n"
                "This fetcher expects the diarizers-community layout (timestamps_start / "
                "timestamps_end / speakers). If the dataset stores its annotation differently, "
                "it needs its own fetcher rather than a manifest entry."
            )

        starts, ends, speakers = row["timestamps_start"], row["timestamps_end"], row["speakers"]
        if not (len(starts) == len(ends) == len(speakers)):
            raise SystemExit(
                f"{entry['id']}: turn columns disagree in length "
                f"({len(starts)}/{len(ends)}/{len(speakers)}) -- refusing to guess the alignment."
            )
        if not starts:
            continue

        raw, extension = extract_audio_bytes(row[audio_column], entry.get("audio_extension", "wav"))
        if raw is None:
            continue

        base = row.get("id") or row.get("file") or row.get("path") or entry["id"]
        name = f"{slugify(str(base))}-{len(written):04d}"
        actual_extension = extension or entry.get("audio_extension", "wav")
        audio_path = out_dir / f"{name}.audio.{actual_extension}"
        audio_path.write_bytes(raw)

        if clip_seconds is not None:
            clipped = out_dir / f"{name}.clipped.{actual_extension}"
            if clip_audio(audio_path, clipped, clip_seconds):
                clipped.replace(audio_path)
            else:
                audio_path.unlink(missing_ok=True)
                continue

        rttm = rttm_lines(name, starts, ends, speakers, clip_seconds)
        if not rttm.strip():
            print(f"[fetch] {entry['id']}: {name} has no turns in range, skipping", file=sys.stderr, flush=True)
            audio_path.unlink(missing_ok=True)
            continue

        (out_dir / f"{name}.reference.rttm").write_text(rttm, encoding="utf-8")
        written.append(name)
        print(
            f"[fetch] {entry['id']}: wrote {name} ({len(raw)} bytes, "
            f"{len(set(speakers))} speaker(s), {len(starts)} turn(s))",
            flush=True,
        )

    if not written:
        raise SystemExit(
            f"{entry['id']}: fetched 0 usable rows out of {row_count} scanned.\n"
            "Check hf_dataset/hf_config/hf_split/audio_column in manifest.json, and -- for a "
            "gated dataset -- that a valid HF token is set and the account has accepted the "
            "dataset's terms on huggingface.co."
        )

    (out_dir / "dataset.json").write_text(
        json.dumps(
            {
                "language": entry["language"],
                "corpus": entry["corpus_name"],
                "license": entry.get("license", ""),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"[fetch] {entry['id']}: wrote {len(written)} item(s) to {out_dir}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--id", required=True)
    parser.add_argument("--hf-dataset", required=True)
    parser.add_argument("--hf-config")
    parser.add_argument("--hf-split", default="test")
    parser.add_argument("--audio-column", default="audio")
    parser.add_argument("--audio-extension", default="wav")
    parser.add_argument("--sample-count", type=int, default=4)
    parser.add_argument("--clip-seconds", type=float)
    parser.add_argument("--language", default="english")
    parser.add_argument("--corpus-name", default="")
    parser.add_argument("--license", default="")
    parser.add_argument("--token")
    args = parser.parse_args()

    fetch(
        {
            "id": args.id,
            "hf_dataset": args.hf_dataset,
            "hf_config": args.hf_config,
            "hf_split": args.hf_split,
            "audio_column": args.audio_column,
            "audio_extension": args.audio_extension,
            "sample_count": args.sample_count,
            "clip_seconds": args.clip_seconds,
            "language": args.language,
            "corpus_name": args.corpus_name or args.id,
            "license": args.license,
        },
        args.out,
        token=args.token,
    )


if __name__ == "__main__":
    main()
