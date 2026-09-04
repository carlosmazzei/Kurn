#!/usr/bin/env python3
"""Convert an .xcresult bundle's coverage archive into an lcov tracefile.

`xcodebuild test -enableCodeCoverage YES` records per-line coverage in the
result bundle; `xcrun xccov view --archive` is the only stable way to read it
back, and it is what Xcode's own coverage pane uses. Reading the bundle rather
than `Coverage.profdata` + the instrumented binaries means the export sees the
same files Xcode does (including the host app's own sources), instead of
depending on which processes managed to flush a profile before the test host
was torn down.

Usage: xccov_to_lcov.py <TestResults.xcresult> <output.lcov> [ignore-regex]
"""

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


def file_records(bundle: str, path: str) -> str:
    lines = []
    hit = 0
    for raw in xccov("--file", path, bundle).splitlines():
        match = LINE_RE.match(raw)
        if not match or match.group(2) == "*":
            continue
        count = int(match.group(2))
        hit += count > 0
        lines.append(f"DA:{match.group(1)},{count}")
    if not lines:
        return ""
    return "\n".join([f"SF:{path}", *lines, f"LF:{len(lines)}", f"LH:{hit}", "end_of_record"]) + "\n"


def main() -> int:
    bundle, output = sys.argv[1], sys.argv[2]
    ignore = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None

    files = sorted(
        path
        for path in xccov("--file-list", bundle).splitlines()
        if path and not (ignore and ignore.search(path))
    )
    if not files:
        print("no coverable source files in the result bundle", file=sys.stderr)
        return 1

    with ThreadPoolExecutor(max_workers=8) as pool:
        records = list(pool.map(lambda path: file_records(bundle, path), files))

    with open(output, "w") as out:
        out.write("".join(records))

    exported = sum(1 for record in records if record)
    print(f"exported {exported} source files to {output}")
    for path in files:
        print(f"  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
