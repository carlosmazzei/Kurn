#!/usr/bin/env python3
"""Fetch a small subset of a Hugging Face audio+transcript dataset.

Writes `<name>.audio.<ext>` + `<name>.reference.txt` + `dataset.json` into the
layout `PublicEvaluationDataset` (`KurnTests/Support/Evaluation/`) reads.

Pulls raw encoded audio bytes with `Audio(decode=False)` instead of decoding,
so nothing beyond `datasets` + `huggingface_hub` needs to be installed -- no
`soundfile`, `librosa`, or `ffmpeg` audio backend. What lands on disk is the
same FLAC/MP3/WAV bytes the corpus ships, in the container the app's own
`AVAudioFile` already knows how to read.

See README.md for what each corpus needs (gated datasets need an `HF_TOKEN`
whose account has accepted the dataset's terms once, on huggingface.co).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def slugify(text: str, limit: int = 40) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", text.strip()).strip("-").lower()
    return slug[:limit] or "item"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest-entry", required=True, type=Path, help="JSON file with one manifest.json corpus entry")
    parser.add_argument("--out", required=True, type=Path, help="output directory for this corpus")
    parser.add_argument("--token", default=None, help="Hugging Face token, for gated datasets")
    args = parser.parse_args()

    entry = json.loads(args.manifest_entry.read_text(encoding="utf-8"))

    try:
        from datasets import Audio, load_dataset
    except ImportError as error:
        raise SystemExit(
            "missing dependency: pip install datasets huggingface_hub "
            "(see Tools/evaluation/public_datasets/README.md)"
        ) from error

    args.out.mkdir(parents=True, exist_ok=True)

    print(f"[fetch] {entry['id']}: loading {entry['hf_dataset']} ({entry.get('hf_config')}) split={entry['hf_split']}")
    dataset = load_dataset(
        entry["hf_dataset"],
        entry.get("hf_config"),
        split=entry["hf_split"],
        streaming=True,
        token=args.token,
        trust_remote_code=entry.get("trust_remote_code", False),
    )
    dataset = dataset.cast_column(entry["audio_column"], Audio(decode=False))

    sample_count = int(entry["sample_count"])
    written: list[str] = []
    for row in dataset:
        if len(written) >= sample_count:
            break

        text = (row.get(entry["text_column"]) or "").strip()
        if not text:
            continue

        audio = row[entry["audio_column"]]
        raw = audio.get("bytes") if isinstance(audio, dict) else None
        if not raw:
            # A streamed row without embedded bytes (only a remote path) can't
            # be written out standalone; skip rather than guess at a download.
            continue

        base = row.get("id") or row.get("path") or entry["id"]
        name = f"{slugify(str(base))}-{len(written):04d}"
        (args.out / f"{name}.audio.{entry['audio_extension']}").write_bytes(raw)
        (args.out / f"{name}.reference.txt").write_text(text + "\n", encoding="utf-8")
        written.append(name)

    if not written:
        raise SystemExit(
            f"{entry['id']}: fetched 0 usable rows out of the stream.\n"
            "Check hf_dataset/hf_config/hf_split/text_column/audio_column in manifest.json, "
            "and -- for a gated dataset -- that --token is a valid HF token whose account has "
            "accepted the dataset's terms on huggingface.co."
        )

    (args.out / "dataset.json").write_text(
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
    print(f"[fetch] {entry['id']}: wrote {len(written)} item(s) to {args.out}")


if __name__ == "__main__":
    sys.exit(main())
