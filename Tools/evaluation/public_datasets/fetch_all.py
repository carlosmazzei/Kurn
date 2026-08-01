#!/usr/bin/env python3
"""Fetch every enabled corpus in manifest.json into an output directory.

    python3 fetch_all.py --out ~/kurn-eval-public

Then point `KURN_PUBLIC_EVAL_DATA` at that directory when running
`KurnTests/PublicDatasetEvaluationHarnessTests`. See README.md for what each
corpus needs -- network access, an `HF_TOKEN` for gated ones, `ffmpeg` for AMI.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, default=HERE / "manifest.json")
    parser.add_argument("--out", type=Path, required=True, help="root directory to write corpora into")
    parser.add_argument("--only", nargs="*", help="corpus id(s) to fetch; default is every enabled entry")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    token = os.environ.get("HF_TOKEN")

    failures: list[str] = []
    for entry in manifest["corpora"]:
        if args.only and entry["id"] not in args.only:
            continue
        if not entry.get("enabled", True):
            print(f"[fetch] skipping {entry['id']} (disabled in manifest.json)")
            continue
        if entry.get("requires_token") and not token:
            print(f"[fetch] skipping {entry['id']}: needs HF_TOKEN (gated dataset) and none is set", file=sys.stderr)
            failures.append(entry["id"])
            continue

        out_dir = args.out / entry["id"]
        try:
            if entry["kind"] == "huggingface_audio":
                fetch_huggingface_audio(entry, out_dir, token)
            elif entry["kind"] == "ami_rttm":
                fetch_ami(entry, out_dir)
            else:
                raise SystemExit(f"unknown corpus kind {entry['kind']!r} for {entry['id']}")
        except subprocess.CalledProcessError:
            failures.append(entry["id"])

    if failures:
        raise SystemExit(f"failed to fetch: {', '.join(failures)}")
    print(f"[fetch] done -- corpora written under {args.out}")


def fetch_huggingface_audio(entry: dict, out_dir: Path, token: str | None) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(entry, handle)
        entry_path = handle.name
    command = [
        sys.executable,
        str(HERE / "fetch_huggingface_audio_dataset.py"),
        "--manifest-entry",
        entry_path,
        "--out",
        str(out_dir),
    ]
    if entry.get("requires_token"):
        command += ["--token", token or ""]
    subprocess.run(command, check=True)


def fetch_ami(entry: dict, out_dir: Path) -> None:
    subprocess.run(
        [
            sys.executable,
            str(HERE / "fetch_ami.py"),
            "--out",
            str(out_dir),
            "--meeting-count",
            str(entry.get("meeting_count", 2)),
            "--clip-seconds",
            str(entry.get("clip_seconds", 300)),
            "--language",
            entry["language"],
            "--license",
            entry.get("license", ""),
            "--corpus-name",
            entry["corpus_name"],
        ],
        check=True,
    )


if __name__ == "__main__":
    sys.exit(main())
