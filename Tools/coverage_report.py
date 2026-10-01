#!/usr/bin/env python3
"""Summarize one or more lcov tracefiles as a Markdown table, per layer.

Codecov reports the total; this answers "where did it move" for a single CI
run, which is what a reviewer needs when a PR adds or removes tests. Lines are
unioned across the given tracefiles (a line counts as hit if any run hit it),
so passing both the unit-test and UI-test lcov gives the combined figure.
Layers outside the gate's scope (`Tools/coverage_scope.json`) are marked, so
the table and `coverage_gate.py` never disagree about what counts.

Usage: coverage_report.py [--top N] [--root PATH] file.lcov [file.lcov ...]

Paths are shown relative to `--root` (default: the first `/Kurn/Kurn/`
segment in the path, which is how the CI runner lays the checkout out).
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lcov import Scope, layer_of, parse, pct, per_file, per_layer  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("files", nargs="+")
    parser.add_argument("--top", type=int, default=25)
    parser.add_argument("--root")
    args = parser.parse_args()

    hits: dict = {}
    for path in args.files:
        parse(path, hits, args.root)
    if not hits:
        print("no coverage data", file=sys.stderr)
        return 1

    scope = Scope.load()
    files = per_file(hits)
    layers = per_layer(files)
    scoped = {rel: v for rel, v in files.items() if scope.contains(rel)}

    all_total = sum(t for t, _ in files.values())
    all_hit = sum(h for _, h in files.values())
    in_total = sum(t for t, _ in scoped.values())
    in_hit = sum(h for _, h in scoped.values())
    print(f"**Total:** {pct(all_hit, all_total).strip()} of {all_total} lines in {len(files)} files "
          f"· **in gate scope:** {pct(in_hit, in_total).strip()} of {in_total} lines\n")

    print("| Layer | Lines | Covered | Uncovered | Gate |")
    print("|---|---:|---:|---:|:---:|")
    for layer, (total, hit) in sorted(layers.items(), key=lambda item: item[1][1] - item[1][0]):
        members = [rel for rel in files if layer_of(rel) == layer]
        gated = "✓" if any(scope.contains(rel) for rel in members) else "—"
        print(f"| `{layer}` | {total} | {pct(hit, total).strip()} | {total - hit} | {gated} |")

    print(f"\n<details><summary>Top {args.top} in-scope files by uncovered lines</summary>\n")
    print("| File | Lines | Covered | Uncovered |")
    print("|---|---:|---:|---:|")
    ranked = sorted(scoped.items(), key=lambda item: item[1][1] - item[1][0])
    for rel, (total, hit) in ranked[: args.top]:
        print(f"| `{rel}` | {total} | {pct(hit, total).strip()} | {total - hit} |")
    print("\n</details>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
