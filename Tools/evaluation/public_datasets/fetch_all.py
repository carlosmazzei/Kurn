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


def _scoring_description(entry: dict) -> str:
    kind = entry.get("kind")
    if kind == "huggingface_audio":
        return "WER"
    if kind == "huggingface_diarization":
        return "DER"
    if kind == "ami_rttm":
        # The transcript is best-effort (see fetch_ami.py); a meeting that loses
        # it falls back to DER, so promise the metric that is always there.
        return "DER (+WER when AMI's manual annotation is reachable)"
    return "unknown"


def _format_corpus(entry: dict) -> str:
    kind = entry.get("kind")
    if kind == "huggingface_audio":
        count = f"{entry.get('sample_count', '?')} sample(s)"
    elif kind == "huggingface_diarization":
        clip = entry.get("clip_seconds")
        clip_note = f", {clip}s clips" if clip else ", full length"
        count = f"{entry.get('sample_count', '?')} recording(s){clip_note}"
    elif kind == "ami_rttm":
        count = f"{entry.get('meeting_count', '?')} meeting(s), {entry.get('clip_seconds', '?')}s clips"
    else:
        count = "?"
    token_note = " (requires HF_TOKEN)" if entry.get("requires_token") else ""
    return f"{entry['id']}: {entry.get('corpus_name', entry['id'])} [{entry.get('language', '?')}] -> {_scoring_description(entry)} ({count}){token_note}"


def print_summary(manifest: dict, token: str | None, only: list[str] | None) -> None:
    enabled: list[dict] = []
    skipped: list[tuple[dict, str]] = []
    for entry in manifest["corpora"]:
        if only and entry["id"] not in only:
            skipped.append((entry, "not selected by --only"))
            continue
        if not entry.get("enabled", True):
            skipped.append((entry, "disabled in manifest"))
            continue
        if entry.get("requires_token") and not token:
            skipped.append((entry, "missing HF_TOKEN"))
            continue
        enabled.append(entry)

    print("[fetch] summary", flush=True)
    if not enabled:
        print("[fetch]   no enabled corpora to fetch", flush=True)
    else:
        total_items = 0
        for entry in enabled:
            print(f"[fetch]   fetch {_format_corpus(entry)}", flush=True)
            if entry.get("kind") in ("huggingface_audio", "huggingface_diarization"):
                total_items += int(entry.get("sample_count", 0))
            elif entry.get("kind") == "ami_rttm":
                total_items += int(entry.get("meeting_count", 0))
        print(f"[fetch]   {len(enabled)} corpus/corpora, ~{total_items} item(s) total", flush=True)
    if skipped:
        print("[fetch] skipped", flush=True)
        for entry, reason in skipped:
            print(f"[fetch]   {entry['id']}: {reason}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, default=HERE / "manifest.json")
    parser.add_argument("--out", type=Path, required=True, help="root directory to write corpora into")
    parser.add_argument("--only", nargs="*", help="corpus id(s) to fetch; default is every enabled entry")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    token = os.environ.get("HF_TOKEN")

    print_summary(manifest, token, args.only)

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
            elif entry["kind"] == "huggingface_diarization":
                from fetch_huggingface_diarization_dataset import fetch as fetch_diarization

                fetch_diarization(entry, out_dir, token=token)
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
        print(f"[fetch] failed to fetch: {', '.join(failures)}", file=sys.stderr, flush=True)
        os._exit(1)
    print(f"[fetch] done -- corpora written under {args.out}", flush=True)
    # The datasets/fsspec stack can leave non-daemon background threads (e.g.
    # HTTP connection pools, file-system monitors) that prevent the interpreter
    # from shutting down cleanly. For a batch fetch script there is no state to
    # flush, so exit immediately.
    os._exit(0)


if __name__ == "__main__":
    main()
