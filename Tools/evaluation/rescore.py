#!/usr/bin/env python3
"""Re-score a pipeline-eval run with the industry's reference scorers.

`PublicDatasetEvaluationHarnessTests` scores WER and DER with this repository's
own implementations (`KurnTests/Support/Evaluation/`). Those are deliberately
simple and comparable *between runs*, but two things they cannot do on their
own: prove that they compute what the standard tools compute, and produce a
number comparable to published results. This script does both, from the same
pipeline output -- the harness writes every cell's hypothesis to a JSON Lines
file (`KURN_PUBLIC_EVAL_HYPOTHESES`) and nothing is re-run.

For every (item, configuration) it reports:

- **WER (kurn)** -- this repo's normalizer re-implemented here, aligned by
  `jiwer`. With `--report` it is checked against the harness's CSV: any
  difference is a bug in one of the two scorers, not a property of the audio.
- **WER (standard)** -- Whisper's `EnglishTextNormalizer` for English and
  `BasicTextNormalizer` otherwise, the convention of the Hugging Face Open ASR
  Leaderboard and most papers since Whisper: numbers, spelling variants,
  contractions and fillers ("um", "uh", "mm") normalized. Only this one is
  loosely comparable to a published figure. The gap between the two says how
  much of the headline WER is formatting rather than recognition.
- **cpWER** -- concatenated minimum-permutation WER (`meeteval`), the
  CHiME-6/7 and NOTSOFAR metric for meeting transcription: the transcript is
  scored *per speaker*, so it measures what the app actually shows -- who said
  what -- where WER and DER each measure only half. Needs a speaker-attributed
  reference (`<name>.reference.seglst.json`, which `fetch_ami.py` writes).
- **DER** -- `pyannote.metrics`, overlap scored, at two collars: +/-0.25 s (the
  NIST RT convention, which the harness uses) and none (the stricter
  convention of DIHARD and pyannote's published benchmarks). Both for the
  fused segments and for the diarizer's raw turns.

Every aggregate is micro-averaged (total errors over total reference), like
the harness.

Usage:

    python3 Tools/evaluation/rescore.py \\
        --data "$KURN_PUBLIC_EVAL_DATA" --hypotheses hypotheses.jsonl \\
        [--report report.csv] [--csv rescore.csv] [--markdown rescore.md]

Requires `Tools/evaluation/rescore-requirements.txt`.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import unicodedata
import warnings
from collections import defaultdict
from pathlib import Path

warnings.filterwarnings("ignore")

try:
    import jiwer
    from meeteval.io import SegLST
    from meeteval.wer import cpwer
    from pyannote.core import Annotation, Segment
    from pyannote.metrics.diarization import DiarizationErrorRate
    from whisper_normalizer.basic import BasicTextNormalizer
    from whisper_normalizer.english import EnglishTextNormalizer
except ImportError as error:  # pragma: no cover - dependency message
    raise SystemExit(
        f"missing dependency ({error}): pip install -r Tools/evaluation/rescore-requirements.txt"
    ) from error

ENGLISH = EnglishTextNormalizer()
BASIC = BasicTextNormalizer()

# pyannote's `collar` is the total width removed around a boundary, so the
# NIST +/-0.25 s convention is 0.5 here.
COLLARS = {"nist": 0.5, "none": 0.0}


# --- Text ---------------------------------------------------------------------


def _unsegmented(character: str) -> bool:
    code = ord(character)
    return (
        0x3040 <= code <= 0x30FF
        or 0x3400 <= code <= 0x4DBF
        or 0x4E00 <= code <= 0x9FFF
        or 0xF900 <= code <= 0xFAFF
    )


def kurn_tokens(text: str) -> list[str]:
    """`TextNormalizer.tokens` (Swift), re-implemented for the cross-check."""
    folded = unicodedata.normalize("NFKC", text).lower()
    words, current = [], []
    for character in folded:
        if character.isalnum():
            current.append(character)
        elif current:
            words.append("".join(current))
            current = []
    if current:
        words.append("".join(current))
    tokens: list[str] = []
    for word in words:
        tokens.extend(list(word) if any(_unsegmented(c) for c in word) else [word])
    return tokens


def standard_tokens(text: str, language: str) -> list[str]:
    normalizer = ENGLISH if language == "english" else BASIC
    normalized = normalizer(text)
    if language in ("chinese", "japanese"):
        return [c for c in normalized if not c.isspace()]
    return normalized.split()


def word_errors(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int, int]:
    """(substitutions, insertions, deletions, reference length), via jiwer."""
    if not reference:
        return 0, len(hypothesis), 0, 0
    if not hypothesis:
        return 0, 0, len(reference), len(reference)
    out = jiwer.process_words(" ".join(reference), " ".join(hypothesis))
    return out.substitutions, out.insertions, out.deletions, len(reference)


# --- Diarization --------------------------------------------------------------


def annotation(turns: list[tuple[str, float, float]]) -> Annotation:
    result = Annotation()
    for index, (label, start, end) in enumerate(turns):
        if end > start:
            result[Segment(start, end), index] = label
    # Same-speaker overlaps merged, as md-eval does; a label is on or off.
    return result.support()


def read_rttm(path: Path) -> list[tuple[str, float, float]]:
    turns = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) >= 8 and fields[0] == "SPEAKER":
            try:
                start, duration = float(fields[3]), float(fields[4])
            except ValueError:
                continue
            if duration > 0:
                turns.append((fields[7], start, start + duration))
    return turns


def diarization_errors(reference: Annotation, hypothesis: Annotation, collar: float) -> tuple[float, float]:
    metric = DiarizationErrorRate(collar=collar, skip_overlap=False)
    detail = metric(reference, hypothesis, detailed=True)
    errors = detail["missed detection"] + detail["false alarm"] + detail["confusion"]
    return errors, detail["total"]


# --- Scoring ------------------------------------------------------------------


def score(record: dict, data: Path) -> dict:
    corpus_dir = data / record["corpus"]
    name = record["name"]
    language = record["language"]
    segments = record.get("segments", [])
    row: dict = {key: record[key] for key in ("corpus", "name", "language", "configuration")}

    reference_txt = corpus_dir / f"{name}.reference.txt"
    if reference_txt.exists():
        reference = reference_txt.read_text(encoding="utf-8")
        hypothesis = " ".join(segment.get("text") or "" for segment in segments)
        row["kurn"] = word_errors(kurn_tokens(reference), kurn_tokens(hypothesis))
        row["standard"] = word_errors(standard_tokens(reference, language), standard_tokens(hypothesis, language))

    reference_seglst = corpus_dir / f"{name}.reference.seglst.json"
    if reference_seglst.exists():
        normalize = lambda text: " ".join(standard_tokens(text, language))  # noqa: E731
        reference_entries = [
            {**entry, "words": normalize(entry["words"])}
            for entry in json.loads(reference_seglst.read_text(encoding="utf-8"))
        ]
        hypothesis_entries = [
            {
                "session_id": name,
                "speaker": segment["speaker"],
                "start_time": segment["start"],
                "end_time": segment["end"],
                "words": normalize(segment.get("text") or ""),
            }
            for segment in segments
        ]
        for entry in reference_entries:
            entry["session_id"] = name
        result = cpwer(reference=SegLST(reference_entries), hypothesis=SegLST(hypothesis_entries))[name]
        row["cpwer"] = (result.errors, result.length)

    reference_rttm = corpus_dir / f"{name}.reference.rttm"
    if reference_rttm.exists():
        reference = annotation(read_rttm(reference_rttm))
        fused = annotation([(s["speaker"], s["start"], s["end"]) for s in segments])
        raw = annotation([(t["speaker"], t["start"], t["end"]) for t in record.get("turns", [])])
        for label, collar in COLLARS.items():
            row[f"der_fused_{label}"] = diarization_errors(reference, fused, collar)
            if record.get("turns"):
                row[f"der_raw_{label}"] = diarization_errors(reference, raw, collar)
    return row


def rate(pairs: list[tuple[float, float]]) -> float | None:
    total = sum(reference for _, reference in pairs)
    return None if total <= 0 else 100.0 * sum(errors for errors, _ in pairs) / total


def wer_pair(counts: tuple[int, int, int, int]) -> tuple[float, float]:
    substitutions, insertions, deletions, length = counts
    return substitutions + insertions + deletions, length


COLUMNS = [
    ("WER (kurn)", lambda r: wer_pair(r["kurn"]) if "kurn" in r else None),
    ("WER (standard)", lambda r: wer_pair(r["standard"]) if "standard" in r else None),
    ("cpWER", lambda r: r.get("cpwer")),
    ("DER fused ±0.25s", lambda r: r.get("der_fused_nist")),
    ("DER fused no collar", lambda r: r.get("der_fused_none")),
    ("DER raw ±0.25s", lambda r: r.get("der_raw_nist")),
    ("DER raw no collar", lambda r: r.get("der_raw_none")),
]


def aggregate_markdown(rows: list[dict]) -> str:
    groups: dict[tuple[str, str], dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for row in rows:
        groups[(row["language"], row["corpus"])][row["configuration"]].append(row)

    lines = ["## Re-scored with reference tools", ""]
    for (language, corpus), by_configuration in sorted(groups.items()):
        present = [
            (title, extract)
            for title, extract in COLUMNS
            if any(extract(row) is not None for rows_ in by_configuration.values() for row in rows_)
        ]
        items = len({row["name"] for rows_ in by_configuration.values() for row in rows_})
        lines += [f"`{language}/{corpus}` ({items} item(s))", ""]
        lines.append("| Configuration | " + " | ".join(title for title, _ in present) + " |")
        lines.append("| --- |" + " --- |" * len(present))
        for configuration, members in sorted(by_configuration.items()):
            cells = []
            for _, extract in present:
                value = rate([pair for pair in map(extract, members) if pair is not None])
                cells.append("—" if value is None else f"{value:.2f}%")
            # GitHub splits table cells on "|" even inside a code span.
            label = configuration.replace("|", "\\|")
            lines.append(f"| `{label}` | " + " | ".join(cells) + " |")
        lines.append("")
    return "\n".join(lines)


def cross_check(rows: list[dict], report: Path) -> str:
    """Compare this script's re-derivation with the harness's own CSV."""
    harness: dict[tuple[str, str, str], dict] = {}
    with report.open(encoding="utf-8") as handle:
        for line in csv.DictReader(handle):
            harness[(line["corpus"], line["name"], line["configuration"])] = line

    worst_wer, worst_der, compared = 0.0, 0.0, 0
    for row in rows:
        line = harness.get((row["corpus"], row["name"], row["configuration"]))
        if line is None:
            continue
        compared += 1
        if "kurn" in row and line.get("wer_ref"):
            errors, length = wer_pair(row["kurn"])
            harness_errors = sum(int(line[key]) for key in ("wer_sub", "wer_ins", "wer_del"))
            if length:
                worst_wer = max(worst_wer, abs(errors - harness_errors) / length * 100)
        if "der_fused_nist" in row and line.get("der_pct"):
            errors, total = row["der_fused_nist"]
            if total:
                worst_der = max(worst_der, abs(100 * errors / total - float(line["der_pct"])))
    return (
        f"Cross-check against the harness CSV over {compared} cell(s): "
        f"max |ΔWER| = {worst_wer:.4f} pp (kurn normalizer), "
        f"max |ΔDER| = {worst_der:.4f} pp (fused, ±0.25 s). "
        "Anything above rounding noise means the two scorers disagree."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", required=True, type=Path, help="KURN_PUBLIC_EVAL_DATA directory")
    parser.add_argument("--hypotheses", required=True, type=Path, help="JSON Lines written by the harness")
    parser.add_argument("--report", type=Path, help="the harness's report.csv, for the cross-check")
    parser.add_argument("--csv", type=Path, help="write per-cell results here")
    parser.add_argument("--markdown", type=Path, help="write the aggregate tables here (default: stdout)")
    args = parser.parse_args()

    if not args.hypotheses.exists():
        raise SystemExit(f"{args.hypotheses}: not found")

    rows = []
    for number, line in enumerate(args.hypotheses.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            rows.append(score(json.loads(line), args.data))
        except Exception as error:  # noqa: BLE001 - one bad cell must not lose the rest
            print(f"[rescore] line {number}: {error}", file=sys.stderr)

    markdown = aggregate_markdown(rows)
    if args.report and args.report.exists():
        markdown += "\n" + cross_check(rows, args.report) + "\n"

    if args.csv:
        fields = ["corpus", "name", "language", "configuration"] + [title for title, _ in COLUMNS]
        with args.csv.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(fields)
            for row in rows:
                values = []
                for _, extract in COLUMNS:
                    pair = extract(row)
                    values.append("" if pair is None or not pair[1] else f"{100 * pair[0] / pair[1]:.4f}")
                writer.writerow([row["corpus"], row["name"], row["language"], row["configuration"], *values])

    if args.markdown:
        args.markdown.write_text(markdown, encoding="utf-8")
    else:
        print(markdown)


if __name__ == "__main__":
    main()
