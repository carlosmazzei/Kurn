#!/usr/bin/env python3
"""Print the crashed process's threads from macOS/simulator `.ips` crash reports.

A test host that aborts mid-run (for example the simulator's audio stack
calling `abort()` with "AURemoteIO: RPC timeout. Apparently deadlocked") leaves
only the abort message in the xcodebuild log; the backtraces that say which
test was touching audio at that moment are in a `.ips` report under
`~/Library/Logs/DiagnosticReports`. CI uploads that directory as an artifact,
but artifacts expire and are not readable from every place a failure gets
diagnosed, so `collect-failure-diagnostics` also runs this to put the useful
part in the job log itself.

An `.ips` file is one JSON header line followed by a JSON body. For each
report whose process name matches, this prints the termination reason, any
application-specific messages, and every thread with a frame from the app or
its tests (the other threads are system worker pools and say nothing about
who did what), plus the crashed thread in full.

Usage: summarize_crash_reports.py <dir> [process-name-regex] [max-frames]
"""

from __future__ import annotations

import json
import os
import re
import sys

APP_IMAGE = re.compile(r"^(Kurn|KurnTests|KurnSwiftDataTests|KurnCore)\b")


def parse(path: str) -> tuple[dict, dict] | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            header_line = handle.readline()
            body = handle.read()
        return json.loads(header_line), json.loads(body)
    except (OSError, ValueError):
        return None


def frame_text(frame: dict, images: list[dict]) -> str:
    index = frame.get("imageIndex")
    image = images[index].get("name", "?") if isinstance(index, int) and 0 <= index < len(images) else "?"
    symbol = frame.get("symbol") or f"+{frame.get('imageOffset', '?')}"
    return f"{image}: {symbol}"


def summarize(header: dict, body: dict, max_frames: int) -> list[str]:
    images = body.get("usedImages") or []
    out = [f"== {header.get('name') or body.get('procName', '?')} ({header.get('timestamp', '?')})"]
    termination = body.get("termination") or {}
    if termination:
        out.append(f"termination: {termination.get('indicator') or termination.get('reason', '?')}")
    exception = body.get("exception") or {}
    if exception:
        out.append(f"exception: {exception.get('type', '?')} {exception.get('signal', '')}".rstrip())
    for image, messages in (body.get("asi") or {}).items():
        for message in messages if isinstance(messages, list) else [messages]:
            out.append(f"message ({image}): {message}")

    for number, thread in enumerate(body.get("threads") or []):
        frames = [frame_text(frame, images) for frame in thread.get("frames") or []]
        crashed = bool(thread.get("triggered"))
        app_frames = [text for text in frames if APP_IMAGE.match(text)]
        if not crashed and not app_frames:
            continue
        label = thread.get("name") or thread.get("queue") or ""
        out.append(f"-- thread {number}{' (crashed)' if crashed else ''} {label}".rstrip())
        shown = frames if crashed else app_frames
        out.extend(f"   {text}" for text in shown[:max_frames])
        if len(shown) > max_frames:
            out.append(f"   … {len(shown) - max_frames} more")
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = argv[1]
    name_filter = re.compile(argv[2] if len(argv) > 2 else r"^(Kurn|xctest)")
    max_frames = int(argv[3]) if len(argv) > 3 else 25

    reports = []
    for directory, _, files in os.walk(root):
        reports.extend(os.path.join(directory, name) for name in files if name.endswith(".ips"))

    printed = 0
    for path in sorted(reports):
        parsed = parse(path)
        if parsed is None:
            continue
        header, body = parsed
        name = header.get("name") or body.get("procName") or ""
        if not name_filter.search(name):
            continue
        print("\n".join(summarize(header, body, max_frames)))
        printed += 1
    if printed == 0:
        print(f"no crash reports matching {name_filter.pattern} under {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
