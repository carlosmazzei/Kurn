#!/usr/bin/env python3
"""Turn what you already have into what the evaluation harness reads.

Two conversions, both of them fiddly by hand and easy to get subtly wrong:

  transcript  the app's Markdown export  ->  <name>.hypothesis.txt
  labels      an Audacity label track    ->  <name>.reference.rttm

Neither invents anything. `transcript` only strips the `**[mm:ss] Name:**`
prefix the export writes; `labels` only reformats columns. If either one has to
guess, it fails loudly instead — a corpus that is quietly wrong produces a
number that looks authoritative and is not.

See README.md for the whole recipe.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# `MeetingExport.renderTranscript` writes one line per segment:
#     **[mm:ss] Speaker name:** the text that was said
# The timestamp is m:ss or h:mm:ss depending on length, and the speaker's
# display name is whatever the user typed, so it can contain almost anything —
# hence the non-greedy match up to the closing `:**`.
SEGMENT = re.compile(r"^\*\*\[[0-9:]+\]\s*(?P<speaker>.+?):\*\*\s*(?P<text>.*)$")


def transcript(source: Path, destination: Path) -> None:
    """Strip the export down to the words, for word error rate.

    WER compares what was said, not who said it or when, and
    `TextNormalizer` will fold case and punctuation anyway. What it must not
    see is the speaker labels and timestamps: those would count as words and
    inflate the denominator with text nobody spoke.
    """
    lines = source.read_text(encoding="utf-8").splitlines()
    spoken: list[str] = []
    for line in lines:
        match = SEGMENT.match(line.strip())
        if match:
            text = match.group("text").strip()
            if text:
                spoken.append(text)

    if not spoken:
        raise SystemExit(
            f"{source}: found no '**[mm:ss] Name:** text' lines.\n"
            "Is this the app's Markdown export, and does it include the "
            "Transcript section?"
        )

    destination.write_text(" ".join(spoken) + "\n", encoding="utf-8")
    print(f"{destination}: {len(spoken)} segment(s), {sum(len(s.split()) for s in spoken)} words")


def labels(source: Path, destination: Path, file_id: str) -> None:
    """Audacity's exported label track -> RTTM.

    Audacity writes `start<TAB>end<TAB>label`, seconds as decimals. RTTM wants
    `start` and *duration*, which is the one conversion worth automating: doing
    it by hand across a few hundred turns is where a corpus quietly acquires
    negative-length segments.
    """
    rows: list[str] = []
    for number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            raise SystemExit(
                f"{source}:{number}: expected 'start<TAB>end<TAB>label', got: {line!r}\n"
                "In Audacity: File > Export > Export Labels."
            )
        try:
            start, end = float(parts[0]), float(parts[1])
        except ValueError as error:
            raise SystemExit(f"{source}:{number}: {error}") from error

        speaker = parts[2].strip()
        if not speaker:
            raise SystemExit(
                f"{source}:{number}: the label has no text. Every turn needs a "
                "speaker name — that is the whole annotation."
            )
        # A speaker name with a space would split into extra RTTM columns and be
        # read back truncated, which is a silent corruption of the reference.
        if " " in speaker:
            raise SystemExit(
                f"{source}:{number}: speaker {speaker!r} contains a space. RTTM is "
                "space-separated; use 'Ana_Souza' or just 'Ana'."
            )
        if end <= start:
            raise SystemExit(
                f"{source}:{number}: label ends at {end} but starts at {start}."
            )
        rows.append(
            f"SPEAKER {file_id} 1 {start:.3f} {end - start:.3f} <NA> <NA> {speaker} <NA> <NA>"
        )

    if not rows:
        raise SystemExit(f"{source}: no labels found.")

    destination.write_text("\n".join(rows) + "\n", encoding="utf-8")
    speakers = sorted({row.split()[7] for row in rows})
    total = sum(float(row.split()[4]) for row in rows)
    print(
        f"{destination}: {len(rows)} turn(s), {len(speakers)} speaker(s) "
        f"({', '.join(speakers)}), {total:.1f}s of speech"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    text = sub.add_parser("transcript", help="Markdown export -> .hypothesis.txt")
    text.add_argument("source", type=Path, help="the .md the app exported")
    text.add_argument("--out", type=Path, required=True, help="<name>.hypothesis.txt")

    label = sub.add_parser("labels", help="Audacity labels -> .reference.rttm")
    label.add_argument("source", type=Path, help="the exported label .txt")
    label.add_argument("--out", type=Path, required=True, help="<name>.reference.rttm")
    label.add_argument(
        "--file-id",
        help="RTTM file identifier; defaults to the output's base name",
    )

    args = parser.parse_args()
    if not args.source.exists():
        raise SystemExit(f"{args.source}: no such file")

    if args.command == "transcript":
        transcript(args.source, args.out)
    else:
        file_id = args.file_id or args.out.name.split(".")[0]
        labels(args.source, args.out, file_id)


if __name__ == "__main__":
    sys.exit(main())
