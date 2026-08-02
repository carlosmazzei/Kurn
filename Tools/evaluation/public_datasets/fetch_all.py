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
import sys
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
            print(f"[fetch] skipping {entry['id']} (disabled in manifest.json)", flush=True)
            continue
        if entry.get("requires_token") and not token:
            print(f"[fetch] skipping {entry['id']}: needs HF_TOKEN (gated dataset) and none is set", file=sys.stderr, flush=True)
            failures.append(entry["id"])
            continue

        out_dir = args.out / entry["id"]
        try:
            if entry["kind"] == "huggingface_audio":
                from fetch_huggingface_audio_dataset import fetch as fetch_huggingface

                fetch_huggingface(entry, out_dir, token=token)
            elif entry["kind"] == "ami_rttm":
                from fetch_ami import fetch as fetch_ami

                fetch_ami(entry, out_dir)
            else:
                raise SystemExit(f"unknown corpus kind {entry['kind']!r} for {entry['id']}")
        except SystemExit as error:
            print(f"[fetch] failed to fetch {entry['id']}: {error}", file=sys.stderr, flush=True)
            failures.append(entry["id"])
        except Exception as error:
            print(f"[fetch] failed to fetch {entry['id']}: {error}", file=sys.stderr, flush=True)
            failures.append(entry["id"])

    if failures:
        raise SystemExit(f"failed to fetch: {', '.join(failures)}")
    print(f"[fetch] done -- corpora written under {args.out}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
