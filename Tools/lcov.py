"""Shared lcov reading and coverage-scope rules for the coverage tools.

`coverage_report.py` (per-layer Markdown table) and `coverage_gate.py` (the
CI gate) both read tracefiles through here, so "which lines count" has one
definition: lines are unioned across tracefiles (a line is hit if any run hit
it), paths are made repository-relative, and `Tools/coverage_scope.json`
decides which files the gate measures.
"""

import fnmatch
import json
import os
from collections import defaultdict

LAYER_DEPTH = {"Kurn": 2, "Packages": 2}
SCOPE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "coverage_scope.json")


def parse(path: str, hits: dict, root: str | None = None) -> None:
    """Adds `(relative path, line) -> max hit count` from one tracefile."""
    current = None
    with open(path) as tracefile:
        for raw in tracefile:
            if raw.startswith("SF:"):
                current = relative(raw[3:].strip(), root)
            elif raw.startswith("DA:") and current is not None:
                line, count = raw[3:].split(",")[:2]
                key = (current, int(line))
                hits[key] = max(hits.get(key, 0), int(count))


def relative(path: str, root: str | None) -> str:
    """Repository-relative form of a tracefile path.

    The unit/UI reports come from a macOS runner and KurnCore's from Linux, so
    their absolute prefixes differ. With a checkout at `root`, the shortest
    suffix that names an existing file wins; otherwise fall back to the
    runner's `<repo>/<repo>/` layout.
    """
    if root:
        root = root.rstrip("/")
        if path.startswith(root + "/"):
            return path[len(root) + 1:]
        parts = path.strip("/").split("/")
        for start in range(len(parts)):
            candidate = "/".join(parts[start:])
            if os.path.isfile(os.path.join(root, candidate)):
                return candidate
    marker = "/Kurn/Kurn/"
    index = path.find(marker)
    return path[index + len(marker):] if index >= 0 else path


def layer_of(rel: str) -> str:
    parts = rel.split("/")
    depth = LAYER_DEPTH.get(parts[0], 1)
    return "/".join(parts[:depth]) if len(parts) > depth else parts[0]


def pct(hit: int, total: int) -> str:
    return f"{100 * hit / total:5.1f}%" if total else "  n/a"


def per_file(hits: dict) -> dict:
    """`relative path -> [executable lines, covered lines]`."""
    files = defaultdict(lambda: [0, 0])
    for (path, _line), count in hits.items():
        entry = files[path]
        entry[0] += 1
        entry[1] += count > 0
    return files


def per_layer(files: dict) -> dict:
    layers = defaultdict(lambda: [0, 0])
    for rel, (total, hit) in files.items():
        entry = layers[layer_of(rel)]
        entry[0] += total
        entry[1] += hit
    return layers


class Scope:
    """Which files the gate measures: under an `include` root and not
    matching an `exclude` pattern. Patterns are fnmatch globs where a
    trailing `/**` means "anything below this directory"."""

    def __init__(self, include: list[str], exclude: list[dict]):
        self.include = include
        self.exclude = exclude

    @classmethod
    def load(cls, path: str = SCOPE_FILE) -> "Scope":
        with open(path) as handle:
            data = json.load(handle)
        return cls(data["include"], data["exclude"])

    def exclusion_for(self, rel: str) -> dict | None:
        for entry in self.exclude:
            pattern = entry["pattern"]
            if pattern.endswith("/**"):
                if rel.startswith(pattern[:-2]):
                    return entry
            elif fnmatch.fnmatchcase(rel, pattern):
                return entry
        return None

    def contains(self, rel: str) -> bool:
        if not any(rel.startswith(root) for root in self.include):
            return False
        return self.exclusion_for(rel) is None
