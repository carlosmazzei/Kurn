#!/usr/bin/env python3
"""Fail CI when coverage of the in-scope code regresses or new code is untested.

Two checks over the union of the given lcov tracefiles, restricted to the
files `Tools/coverage_scope.json` puts in scope (app logic and KurnCore; not
SwiftUI views, debug glue or the adapter shells it lists):

* **Floor (ratchet).** The in-scope total and every layer must stay within
  `tolerance` points of `Tools/coverage_floor.json`. A PR that raises
  coverage records the new values with `--write-floor`; the floor only moves
  up. A `null` total means "not measured yet": the gate reports and passes.
* **Patch.** With `--patch-base`, the executable lines the diff adds to
  in-scope files must be covered at `--patch-min` (default 80%). Added lines
  the tracefiles do not mark executable (comments, declarations, blank lines)
  do not count either way.

Usage:
  coverage_gate.py [--root PATH] [--floor FILE] [--write-floor]
                   [--patch-base REV [--patch-head REV]] [--patch-min PCT]
                   file.lcov [file.lcov ...]

Writes a Markdown summary to stdout (CI appends it to the job summary) and
GitHub `::error`/`::warning` annotations to stderr.
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lcov  # noqa: E402

FLOOR_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "coverage_floor.json")
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
MAX_ANNOTATIONS = 50


def percent(hit: int, total: int) -> float:
    return 100.0 * hit / total if total else 100.0


def floor_down(value: float) -> float:
    return math.floor(value * 10) / 10


def added_lines(diff_text: str) -> dict:
    """`path -> set of new-side line numbers` from `git diff -U0` output."""
    added: dict = {}
    current = None
    for raw in diff_text.splitlines():
        if raw.startswith("+++ "):
            target = raw[4:].strip()
            current = None if target == "/dev/null" else target[2:] if target.startswith("b/") else target
        elif raw.startswith("@@") and current is not None:
            match = HUNK.match(raw)
            if match:
                start = int(match.group(1))
                count = int(match.group(2)) if match.group(2) is not None else 1
                added.setdefault(current, set()).update(range(start, start + count))
    return added


def git_diff(base: str, head: str, root: str) -> str:
    return subprocess.run(
        ["git", "-C", root, "diff", "-U0", "--no-color", "--no-ext-diff", base, head],
        check=True, capture_output=True, text=True,
    ).stdout


def ranges(lines: list[int]) -> str:
    spans, start, prev = [], None, None
    for line in sorted(lines):
        if start is None:
            start = prev = line
        elif line == prev + 1:
            prev = line
        else:
            spans.append((start, prev))
            start = prev = line
    if start is not None:
        spans.append((start, prev))
    return ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in spans)


def check_floor(files: dict, scope: lcov.Scope, floor: dict, out) -> tuple[list[str], dict]:
    in_scope = {rel: v for rel, v in files.items() if scope.contains(rel)}
    total = sum(t for t, _ in in_scope.values())
    hit = sum(h for _, h in in_scope.values())
    measured = {"total": percent(hit, total), "layers": {}}
    for layer, (lt, lh) in lcov.per_layer(in_scope).items():
        measured["layers"][layer] = percent(lh, lt)

    target = floor.get("target")
    tolerance = floor.get("tolerance", 0.0)
    print(f"**In scope:** {measured['total']:.1f}% of {total} lines in {len(in_scope)} files"
          + (f" (target {target:.0f}%)" if target else ""), file=out)
    print("\n| Layer | Lines | Covered | Floor |", file=out)
    print("|---|---:|---:|---:|", file=out)
    layer_totals = lcov.per_layer(in_scope)
    for layer in sorted(layer_totals, key=lambda name: measured["layers"][name]):
        lt, _ = layer_totals[layer]
        recorded = floor.get("layers", {}).get(layer)
        shown = f"{recorded:.1f}%" if recorded is not None else "—"
        print(f"| `{layer}` | {lt} | {measured['layers'][layer]:.1f}% | {shown} |", file=out)

    failures = []
    if floor.get("total") is None:
        print("\n_No floor recorded yet: run `coverage_gate.py --write-floor` and commit "
              "`Tools/coverage_floor.json`._", file=out)
        return failures, measured
    if measured["total"] + tolerance < floor["total"]:
        failures.append(f"in-scope coverage {measured['total']:.1f}% is below the floor "
                        f"{floor['total']:.1f}% (tolerance {tolerance}pp)")
    for layer, recorded in floor.get("layers", {}).items():
        value = measured["layers"].get(layer)
        if value is None:
            continue
        if value + tolerance < recorded:
            failures.append(f"`{layer}` coverage {value:.1f}% is below its floor {recorded:.1f}%")
    return failures, measured


def check_patch(hits: dict, scope: lcov.Scope, diff: dict, minimum: float, out) -> list[str]:
    executable: dict = {}
    for (rel, line), count in hits.items():
        executable.setdefault(rel, {})[line] = count

    rows, uncovered_by_file, not_reported = [], {}, []
    total = hit = 0
    for rel, lines in sorted(diff.items()):
        if not scope.contains(rel) or not rel.endswith(".swift"):
            continue
        if rel not in executable:
            not_reported.append(rel)
            continue
        counted = [line for line in lines if line in executable[rel]]
        if not counted:
            continue
        covered = [line for line in counted if executable[rel][line] > 0]
        missed = [line for line in counted if executable[rel][line] == 0]
        total += len(counted)
        hit += len(covered)
        rows.append((rel, len(counted), len(covered), missed))
        if missed:
            uncovered_by_file[rel] = missed

    print("\n### Patch coverage", file=out)
    if not total:
        print("\nNo executable in-scope lines changed.", file=out)
    else:
        value = percent(hit, total)
        print(f"\n**{value:.1f}%** of {total} changed executable lines (minimum {minimum:.0f}%)\n", file=out)
        print("| File | Changed | Covered | Uncovered lines |", file=out)
        print("|---|---:|---:|---|", file=out)
        for rel, count, covered, missed in rows:
            print(f"| `{rel}` | {count} | {covered} | {ranges(missed) or '—'} |", file=out)

    annotations = 0
    for rel, missed in uncovered_by_file.items():
        for line in sorted(missed):
            if annotations >= MAX_ANNOTATIONS:
                break
            print(f"::warning file={rel},line={line}::Line added by this change is not covered by tests",
                  file=sys.stderr)
            annotations += 1
    for rel in not_reported:
        print(f"::warning file={rel}::In-scope file changed but absent from every coverage report",
              file=sys.stderr)

    if total and percent(hit, total) < minimum:
        return [f"patch coverage {percent(hit, total):.1f}% is below {minimum:.0f}% "
                f"({total - hit} of {total} changed executable lines uncovered)"]
    return []


def write_floor(path: str, floor: dict, measured: dict) -> None:
    floor["total"] = floor_down(measured["total"])
    floor["layers"] = {layer: floor_down(value) for layer, value in sorted(measured["layers"].items())}
    with open(path, "w") as handle:
        json.dump(floor, handle, indent=2)
        handle.write("\n")


def main(argv: list[str] | None = None, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("files", nargs="+")
    parser.add_argument("--root", default=os.getcwd())
    parser.add_argument("--scope", default=lcov.SCOPE_FILE)
    parser.add_argument("--floor", default=FLOOR_FILE)
    parser.add_argument("--write-floor", action="store_true")
    parser.add_argument("--patch-base")
    parser.add_argument("--patch-head", default="HEAD")
    parser.add_argument("--patch-min", type=float, default=80.0)
    args = parser.parse_args(argv)

    hits: dict = {}
    for path in args.files:
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            print(f"::error::coverage report {path} is missing or empty", file=sys.stderr)
            return 1
        lcov.parse(path, hits, args.root)
    if not hits:
        print("::error::no coverage data in the given reports", file=sys.stderr)
        return 1

    scope = lcov.Scope.load(args.scope)
    with open(args.floor) as handle:
        floor = json.load(handle)

    failures, measured = check_floor(lcov.per_file(hits), scope, floor, out)
    if args.patch_base:
        diff = added_lines(git_diff(args.patch_base, args.patch_head, args.root))
        failures += check_patch(hits, scope, diff, args.patch_min, out)

    if args.write_floor:
        write_floor(args.floor, floor, measured)
        print(f"\nWrote {args.floor}.", file=out)
        return 0

    for failure in failures:
        print(f"::error::{failure}", file=sys.stderr)
    if failures:
        print("\n**Coverage gate failed:** " + "; ".join(failures), file=out)
        return 1
    print("\nCoverage gate passed.", file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
