#!/usr/bin/env python3
"""Convert an .xcresult bundle's coverage archive into an lcov tracefile.

`xcodebuild test -enableCodeCoverage YES` records per-line coverage in the
result bundle; `xcrun xccov view --archive` is the only stable way to read it
back, and it is what Xcode's own coverage pane uses. Reading the bundle rather
than `Coverage.profdata` + the instrumented binaries means the export sees the
same files Xcode does (including the host app's own sources), instead of
depending on which processes managed to flush a profile before the test host
was torn down.

The whole archive is read with one `--json` call. The export used to run one
`xccov --file` process per source file (~500), each re-opening the archive,
which took 2.5-4.5 minutes per CI job; the per-file path is kept only as the
fallback for a toolchain whose JSON shape this script does not recognise.

Usage: xccov_to_lcov.py <TestResults.xcresult> <output.lcov> [ignore-regex]
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

LINE_RE = re.compile(r"^\s*(\d+): (\*|\d+)")


def xccov(*args: str) -> str:
    return subprocess.run(
        ["xcrun", "xccov", "view", "--archive", *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def record(path: str, counts: list[tuple[int, int]]) -> str:
    if not counts:
        return ""
    lines = [f"DA:{line},{count}" for line, count in counts]
    hit = sum(1 for _, count in counts if count > 0)
    return "\n".join([f"SF:{path}", *lines, f"LF:{len(lines)}", f"LH:{hit}", "end_of_record"]) + "\n"


def counts_from_json(entries) -> list[tuple[int, int]] | None:
    """Executable lines of one file from `xccov view --archive --json`, or
    None when the entries are not the expected list of line objects."""
    if not isinstance(entries, list):
        return None
    counts = []
    for entry in entries:
        if not isinstance(entry, dict) or "line" not in entry:
            return None
        if not entry.get("isExecutable"):
            continue
        counts.append((int(entry["line"]), int(entry.get("executionCount") or 0)))
    return counts


def records_from_json(bundle: str, keep) -> dict[str, str] | None:
    """Every file's record from a single `--json` read of the archive, or
    None when the output is not the `{path: [line, ...]}` shape expected."""
    try:
        data = json.loads(xccov("--json", bundle))
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict) or not data:
        return None
    records = {}
    for path, entries in data.items():
        counts = counts_from_json(entries)
        if counts is None:
            return None
        if keep(path):
            records[path] = record(path, counts)
    return records


def file_record(bundle: str, path: str) -> str:
    counts = []
    for raw in xccov("--file", path, bundle).splitlines():
        match = LINE_RE.match(raw)
        if match and match.group(2) != "*":
            counts.append((int(match.group(1)), int(match.group(2))))
    return record(path, counts)


def records_per_file(bundle: str, keep) -> dict[str, str]:
    files = [path for path in xccov("--file-list", bundle).splitlines() if path and keep(path)]
    with ThreadPoolExecutor(max_workers=8) as pool:
        return dict(zip(files, pool.map(lambda path: file_record(bundle, path), files)))


def main() -> int:
    bundle, output = sys.argv[1], sys.argv[2]
    ignore = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None

    def keep(path: str) -> bool:
        return bool(path) and not (ignore and ignore.search(path))

    records = records_from_json(bundle, keep)
    if records is None:
        print("xccov --json output not recognised; reading files one at a time", file=sys.stderr)
        records = records_per_file(bundle, keep)
    if not records:
        print("no coverable source files in the result bundle", file=sys.stderr)
        return 1

    files = sorted(records)
    with open(output, "w") as out:
        out.write("".join(records[path] for path in files))

    exported = sum(1 for path in files if records[path])
    print(f"exported {exported} source files to {output}")
    for path in files:
        print(f"  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
