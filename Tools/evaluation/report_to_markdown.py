#!/usr/bin/env python3
"""Render a pipeline-eval `report.csv` into the Markdown that goes in the docs.

    python3 report_to_markdown.py --csv report.csv --log pipeline-eval.log

`PublicDatasetEvaluationHarnessTests` writes its numbers to two places, both of
which expire: a job summary and a 90-day artifact. `docs/pipeline-evaluation.md`
is where they survive, and this is what gets them there without anybody
retyping a table of sixteen rows.

Two things it deliberately does *not* do.

It does not scrape the `[pipeline-eval] <language> [<label>]: WER ...` aggregate
lines out of the log. Those are already rounded to two decimals, and re-deriving
the aggregate from the CSV's raw counts means the doc and the harness cannot
disagree — the arithmetic here is the same micro-average `reportAggregate` does,
`sum(errors) / sum(reference)` over the corpus, never a mean of per-file rates.

And it does not print the configuration label verbatim. The label's shape has
already changed once (`asr=whisperCpp` became `asr=whisperCpp@small` when the
model sweep landed), so a table built on the raw string would silently stop
lining up with older entries. Splitting it into one column per pipeline stage
survives that.

See public_datasets/README.md for how to produce the CSV in the first place.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import re
import sys
from pathlib import Path

# `writeCSV` in PublicDatasetEvaluationHarnessTests.swift. Checked rather than
# assumed: the harness quotes nothing and escapes nothing, so a column that
# moved would not fail — it would produce a plausible, wrong number.
EXPECTED_HEADER = [
    "corpus",
    "name",
    "language",
    "configuration",
    "wer_pct",
    "wer_sub",
    "wer_ins",
    "wer_del",
    "wer_ref",
    "der_pct",
    "der_missed",
    "der_false_alarm",
    "der_confusion",
    "der_ref_speech",
    "raw_der_pct",
    "raw_der_missed",
    "raw_der_false_alarm",
    "raw_der_confusion",
]

MARKER = "[pipeline-eval] "

# `prep=...|vad=...|diar=...|asr=...`, built at PipelineEvaluationMatrix.swift's
# `label`. `|` rather than `,` is what keeps the label inside one CSV column.
STAGE_COLUMNS = [("prep", "Preprocessing"), ("vad", "VAD"), ("diar", "Diarization"), ("asr", "ASR")]

SKIP_LINE = re.compile(r"^SKIP (?P<corpus>[^/]+)/(?P<item>\S+) \[(?P<label>[^\]]+)\]: (?P<reason>.+)$")


class Group:
    """One (section, configuration) cell of the aggregate table."""

    def __init__(self, section: str, label: str) -> None:
        self.section = section
        self.label = label
        self.corpora: set[str] = set()
        self.wer_errors = 0
        self.wer_reference = 0
        self.wer_files = 0
        self.der_errors = 0.0
        self.der_reference = 0.0
        self.der_files = 0
        self.raw_der_errors = 0.0
        self.raw_der_reference = 0.0
        self.raw_der_files = 0

    def add(self, row: dict[str, str]) -> None:
        self.corpora.add(row["corpus"])
        if row["wer_ref"]:
            self.wer_errors += int(row["wer_sub"]) + int(row["wer_ins"]) + int(row["wer_del"])
            self.wer_reference += int(row["wer_ref"])
            self.wer_files += 1
        if row["der_ref_speech"]:
            self.der_errors += (
                float(row["der_missed"]) + float(row["der_false_alarm"]) + float(row["der_confusion"])
            )
            self.der_reference += float(row["der_ref_speech"])
            self.der_files += 1
        # Raw DER shares the fused DER's reference speech duration — same
        # reference audio, so the CSV doesn't store it a second time.
        if row["raw_der_pct"] and row["der_ref_speech"]:
            self.raw_der_errors += (
                float(row["raw_der_missed"]) + float(row["raw_der_false_alarm"]) + float(row["raw_der_confusion"])
            )
            self.raw_der_reference += float(row["der_ref_speech"])
            self.raw_der_files += 1

    @property
    def wer(self) -> float | None:
        if self.wer_files == 0 or self.wer_reference == 0:
            return None
        return self.wer_errors / self.wer_reference * 100

    @property
    def der(self) -> float | None:
        if self.der_files == 0 or self.der_reference == 0:
            return None
        return self.der_errors / self.der_reference * 100

    @property
    def raw_der(self) -> float | None:
        if self.raw_der_files == 0 or self.raw_der_reference == 0:
            return None
        return self.raw_der_errors / self.raw_der_reference * 100

    @property
    def stages(self) -> list[str]:
        """The label split into one cell per pipeline stage.

        A label that does not parse is not worth guessing at: it is passed
        through in the first column and the rest are left blank, which is
        visibly odd in the rendered table rather than quietly wrong.
        """
        parts = dict(
            piece.split("=", 1) for piece in self.label.split("|") if "=" in piece
        )
        if not all(key in parts for key, _ in STAGE_COLUMNS):
            return [self.label] + [""] * (len(STAGE_COLUMNS) - 1)
        return [parts[key] for key, _ in STAGE_COLUMNS]


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != EXPECTED_HEADER:
            raise SystemExit(
                f"{path}: unexpected CSV header.\n"
                f"  expected: {','.join(EXPECTED_HEADER)}\n"
                f"  found:    {','.join(reader.fieldnames or [])}"
            )
        return list(reader)


def group_rows(rows: list[dict[str, str]], per_corpus: bool) -> dict[str, dict[str, Group]]:
    """section -> configuration label -> Group, both insertion-ordered.

    A section is one language, or one (language, corpus) pair. Both grains are
    rendered because micro-averaging weights by reference length: a language
    total over LibriSpeech plus AMI is dominated by the meeting corpus, which
    buries the read-speech number rather than reporting it.
    """
    grouped: dict[str, dict[str, Group]] = {}
    for row in rows:
        section = f"{row['language']} / {row['corpus']}" if per_corpus else row["language"]
        by_label = grouped.setdefault(section, {})
        group = by_label.get(row["configuration"])
        if group is None:
            group = Group(section, row["configuration"])
            by_label[row["configuration"]] = group
        group.add(row)
    return grouped


def parse_log(path: Path) -> tuple[list[str], list[str], list[str]]:
    """Pull the run summary, the corpus list and the skips out of a run log.

    Returns (summary lines, corpus lines, skip notes). Everything here is
    best-effort: the CSV alone is enough to render a table, and a log that was
    truncated or is from an older harness must not cost us the report.
    """
    summary: list[str] = []
    corpora: list[str] = []
    skips: list[str] = []
    in_summary = False
    in_corpora = False

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        index = raw.find(MARKER)
        if index < 0:
            continue
        line = raw[index + len(MARKER) :].rstrip()

        if line.startswith("=== run summary ==="):
            in_summary, in_corpora = True, False
            continue
        if line.startswith("==="):
            in_summary = in_corpora = False
            continue

        match = SKIP_LINE.match(line)
        if match:
            note = f"`{match['label']}` on {match['corpus']}: {match['reason']}"
            if note not in skips:
                skips.append(note)
            continue

        if not in_summary:
            continue
        # The summary block indents its detail lines; strip that before
        # matching, or the corpus entries fall through and get re-bulleted.
        line = line.strip()
        if line.startswith("corpora:"):
            in_corpora = True
            continue
        if in_corpora and line.startswith("- "):
            corpora.append(line[2:].strip())
            continue
        in_corpora = False
        if line.startswith("total:"):
            summary.append(line)
            in_summary = False
            continue
        summary.append(line)

    return summary, corpora, skips


def table(groups: list[Group]) -> list[str]:
    show_wer = any(group.wer is not None for group in groups)
    show_der = any(group.der is not None for group in groups)
    # Raw DER is scored against the diarizer's own turns, before fusion moved
    # any boundary to match an ASR span — absent from older reports (an
    # earlier CSV schema without the raw_der_* columns), so it's shown only
    # when at least one row actually carries it.
    show_raw_der = any(group.raw_der is not None for group in groups)

    # Item counts get their own column per metric rather than one shared one:
    # a corpus can be WER-only (LibriSpeech) or DER-only (AMI), so within a
    # single language the two counts routinely differ, and one "Items" column
    # would have to be wrong about one of them.
    headers = [label for _, label in STAGE_COLUMNS]
    if show_wer:
        headers += ["WER", "WER items"]
    if show_der:
        headers += ["DER (fused)", "DER (fused) items"]
    if show_raw_der:
        headers += ["DER (raw)", "DER (raw) items"]

    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for group in groups:
        cells = list(group.stages)
        if show_wer:
            cells += ["—", "—"] if group.wer is None else [f"{group.wer:.2f}%", str(group.wer_files)]
        if show_der:
            cells += ["—", "—"] if group.der is None else [f"{group.der:.2f}%", str(group.der_files)]
        if show_raw_der:
            cells += ["—", "—"] if group.raw_der is None else [f"{group.raw_der:.2f}%", str(group.raw_der_files)]
        lines.append("| " + " | ".join(cells) + " |")
    return lines


def sort_key(group: Group) -> tuple[float, str]:
    """Best first. A group with no WER sorts on its DER, and a group with
    neither sorts last rather than at 0% — an absent metric is not a good one."""
    primary = group.wer if group.wer is not None else group.der
    return (float("inf") if primary is None else primary, group.label)


def render(
    rows: list[dict[str, str]],
    date: str,
    commit: str | None,
    run_url: str | None,
    log: Path | None,
) -> str:
    grouped = group_rows(rows, per_corpus=False)
    per_corpus = group_rows(rows, per_corpus=True)

    heading = f"### {date}"
    if commit:
        heading += f" — `{commit}`"
    if run_url:
        heading += f" ([workflow run]({run_url}))"

    out = [heading, ""]

    summary, corpora, skips = parse_log(log) if log and log.exists() else ([], [], [])
    for line in summary:
        out.append(f"- {line}")
    if corpora:
        out.append("- corpora:")
        for corpus in corpora:
            out.append(f"  - {corpus}")
    if not summary and not corpora:
        # No log: say what the CSV itself can prove and nothing more.
        for language, by_label in grouped.items():
            names = sorted({corpus for group in by_label.values() for corpus in group.corpora})
            out.append(f"- {language}: {len(by_label)} configuration(s) over {', '.join(names)}")
    out.append(f"- {len(rows)} scored (item, configuration) row(s)")
    out.append("")

    for language in sorted(grouped):
        out.append(f"#### {language.capitalize()}")
        out.append("")
        out.extend(table(sorted(grouped[language].values(), key=sort_key)))
        out.append("")

    # Only worth printing when some language actually spans more than one
    # corpus; otherwise it is the table above with a longer heading.
    if len(per_corpus) > len(grouped):
        out.append("<details><summary>Per corpus</summary>")
        out.append("")
        for section in sorted(per_corpus):
            out.append(f"##### {section}")
            out.append("")
            out.extend(table(sorted(per_corpus[section].values(), key=sort_key)))
            out.append("")
        out.append("</details>")
        out.append("")

    if skips:
        out.append("Skipped, and therefore absent from the tables above — a skip is not a 0%:")
        out.append("")
        for skip in skips:
            out.append(f"- {skip}")
        out.append("")

    return "\n".join(out).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--csv", required=True, type=Path, help="report.csv from KURN_PUBLIC_EVAL_REPORT")
    parser.add_argument("--log", type=Path, help="pipeline-eval.log, for the run-summary header")
    parser.add_argument("--run-url", help="link to the workflow run")
    parser.add_argument("--commit", help="commit the run was measured at")
    parser.add_argument("--date", help="run date (default: today, UTC)")
    parser.add_argument("--out", type=Path, help="output file (default: stdout)")
    args = parser.parse_args()

    if not args.csv.exists():
        # The harness `#require`s a failure-free run *before* writing the CSV,
        # so a run with any failure produces no file at all. That is a normal
        # outcome to report, not a crash.
        print(f"{args.csv}: no report to render", file=sys.stderr)
        return 1

    rows = read_rows(args.csv)
    if not rows:
        print(f"{args.csv}: no scored rows", file=sys.stderr)
        return 1

    date = args.date or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    commit = args.commit[:7] if args.commit else None
    markdown = render(rows, date, commit, args.run_url, args.log)

    if args.out:
        args.out.write_text(markdown, encoding="utf-8")
    else:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
