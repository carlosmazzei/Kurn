#!/usr/bin/env python3
"""Summarize one or more lcov tracefiles as a Markdown table, per layer.

Codecov reports the total; this answers "where did it move" for a single CI
run, which is what a reviewer needs when a PR adds or removes tests. Lines are
unioned across the given tracefiles (a line counts as hit if any run hit it),
so passing both the unit-test and UI-test lcov gives the combined figure.

Usage: coverage_report.py [--top N] [--root PATH] file.lcov [file.lcov ...]

Paths are shown relative to `--root` (default: the first `/Kurn/` segment in
the path, which is how the CI runner lays the checkout out).
"""

import argparse
import sys
from collections import defaultdict

LAYER_DEPTH = {"Kurn": 2, "Packages": 2}


def parse(path: str, hits: dict) -> None:
    current = None
    with open(path) as tracefile:
        for raw in tracefile:
            if raw.startswith("SF:"):
                current = raw[3:].strip()
            elif raw.startswith("DA:") and current is not None:
                line, count = raw[3:].split(",")[:2]
                key = (current, int(line))
                hits[key] = max(hits.get(key, 0), int(count))


def relative(path: str, root: str | None) -> str:
    if root and path.startswith(root):
        return path[len(root):].lstrip("/")
    marker = "/Kurn/Kurn/"
    index = path.find(marker)
    return path[index + len(marker):] if index >= 0 else path


def layer_of(rel: str) -> str:
    parts = rel.split("/")
    depth = LAYER_DEPTH.get(parts[0], 1)
    return "/".join(parts[:depth]) if len(parts) > depth else parts[0]


def pct(hit: int, total: int) -> str:
    return f"{100 * hit / total:5.1f}%" if total else "  n/a"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("files", nargs="+")
    parser.add_argument("--top", type=int, default=25)
    parser.add_argument("--root")
    args = parser.parse_args()

    hits: dict = {}
    for path in args.files:
        parse(path, hits)
    if not hits:
        print("no coverage data", file=sys.stderr)
        return 1

    per_file = defaultdict(lambda: [0, 0])
    for (path, _line), count in hits.items():
        entry = per_file[relative(path, args.root)]
        entry[0] += 1
        entry[1] += count > 0

    per_layer = defaultdict(lambda: [0, 0])
    for rel, (total, hit) in per_file.items():
        entry = per_layer[layer_of(rel)]
        entry[0] += total
        entry[1] += hit

    all_total = sum(t for t, _ in per_file.values())
    all_hit = sum(h for _, h in per_file.values())
    print(f"**Total:** {pct(all_hit, all_total).strip()} of {all_total} lines in {len(per_file)} files\n")

    print("| Layer | Lines | Covered | Uncovered |")
    print("|---|---:|---:|---:|")
    for layer, (total, hit) in sorted(per_layer.items(), key=lambda item: item[1][1] - item[1][0]):
        print(f"| `{layer}` | {total} | {pct(hit, total).strip()} | {total - hit} |")

    print(f"\n<details><summary>Top {args.top} files by uncovered lines</summary>\n")
    print("| File | Lines | Covered | Uncovered |")
    print("|---|---:|---:|---:|")
    ranked = sorted(per_file.items(), key=lambda item: item[1][1] - item[1][0])
    for rel, (total, hit) in ranked[: args.top]:
        print(f"| `{rel}` | {total} | {pct(hit, total).strip()} | {total - hit} |")
    print("\n</details>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
