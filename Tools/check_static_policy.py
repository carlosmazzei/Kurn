#!/usr/bin/env python3
#
# H10 PR 24: narrow, high-signal static checks for the durability regressions
# this track already found once by manual audit — a production `fatalError`,
# a `ModelContext` save whose failure is silently dropped, an ad hoc
# `URLSession` bypassing the app's origin-locked HTTP policy, and a raw
# error description logged at `.public`. Each check here maps to a change
# CLAUDE.md documents as already fixed once (`ModelContext+Save.swift`,
# `ProviderHTTPTransport.swift`, the four PR 22 log sites) — the goal is to
# stop the same class of regression from being reintroduced silently, not to
# retroactively judge every existing line in the codebase.
#
# Two deliberately narrow items from H10's plan are NOT checked here:
# "unowned long-lived tasks" and "durability-boundary try?" beyond
# `ModelContext.save()`. Both were investigated (13 stored-`Task` properties;
# ~200 `try?` sites) and found to need per-type lifecycle knowledge — is this
# class a per-screen view model or a process-lifetime singleton, is this
# `try?` swallowing a durable commit or a genuinely best-effort operation —
# that a text scan cannot reliably answer. A blanket check here would be
# mostly false positives, which is worse than no check: nobody could act on
# it. These stay manual-audit items, the same way H8 PR 18's concurrency
# bridge audit was done by hand.
#
# Every finding must be either fixed or added to the baseline file
# (grandfathered, keyed by exact line content so it survives unrelated line
# shifts) or given an inline `// static-policy:allow <check>` comment on the
# same line (for a new, deliberate exception). A finding that is neither is
# a new violation and fails CI.
#
# The baseline may only shrink: an entry whose line no longer exists in the
# file it names is reported as stale and fails the check, so a fixed site
# cannot quietly keep its exemption (and later re-grow into it). The check
# prints the remaining baseline size per rule so the number is visible in
# every CI run rather than only to whoever opens the file.

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE_PATH = ROOT / "Tools" / "static_policy_baseline.txt"

# Directories never scanned: test targets (assertions/fixtures legitimately
# use patterns production code shouldn't), and DebugSupport (compiled out of
# Release entirely, per CLAUDE.md).
EXCLUDED_DIR_PARTS = {
    "KurnTests",
    "KurnUITests",
    "KurnSwiftDataTests",
    "KurnWatchUITests",
    "KurnCoreTests",
    "DebugSupport",
    ".build",
    "DerivedData",
}

SOURCE_ROOTS = [
    ROOT / "Kurn",
    ROOT / "KurnWatch",
    ROOT / "KurnLiveActivityExtension",
    ROOT / "Packages" / "KurnCore" / "Sources",
]

ALLOW_COMMENT_RE = re.compile(r"static-policy:allow\s+([A-Za-z0-9_-]+)")


@dataclass(frozen=True)
class Rule:
    name: str
    pattern: re.Pattern[str]
    description: str


RULES = [
    Rule(
        name="fatal-error",
        pattern=re.compile(r"\b(fatalError|preconditionFailure)\s*\("),
        description=(
            "production fatalError/preconditionFailure. If this is a "
            "provably-unreachable case (an exhaustive switch already "
            "guarded above, a validated-by-precondition system call), add "
            "it to Tools/static_policy_baseline.txt or annotate the line "
            "with `// static-policy:allow fatal-error - <reason>`."
        ),
    ),
    Rule(
        name="unchecked-save",
        pattern=re.compile(r"try\?\s*[\w.]*\.save\s*\(\s*\)"),
        description=(
            "a ModelContext save whose failure is silently dropped. Use "
            "ModelContext+Save.swift's `saveOrError()` (or propagate the "
            "throw) instead of `try? context.save()` so a failed commit is "
            "reported rather than leaving memory and disk diverged."
        ),
    ),
    Rule(
        name="custom-url-session",
        pattern=re.compile(r"\bURLSession\s*\("),
        description=(
            "an ad hoc URLSession outside the app's sanctioned transport "
            "seams (ProviderHTTPTransport, ModelFileDownloader, "
            "WhisperBackgroundUploader). New cloud/network traffic should "
            "go through the existing origin-locked, deadline-bounded "
            "policy rather than constructing its own session."
        ),
    ),
    Rule(
        name="raw-public-error",
        pattern=re.compile(
            r"\.(?:localizedDescription|errorDescription)\s*,\s*privacy:\s*\.public"
        ),
        description=(
            "a raw error description logged at `.public`. An AppError's "
            "own errorDescription can embed a raw underlying system "
            "error's text (see privateContext in AppErrorMetadata.swift); "
            "log `publicLogCode` (Error+LogCode.swift) at `.public` and the raw "
            "description at `.private` instead."
        ),
    ),
]

RULES_BY_NAME = {rule.name: rule for rule in RULES}


def iter_source_files() -> list[Path]:
    files: list[Path] = []
    for root in SOURCE_ROOTS:
        if not root.is_dir():
            continue
        for path in root.rglob("*.swift"):
            if any(part in EXCLUDED_DIR_PARTS for part in path.parts):
                continue
            files.append(path)
    return sorted(files)


def load_baseline() -> dict[str, set[tuple[str, str]]]:
    """check name -> set of (relative path, stripped line content)."""
    baseline: dict[str, set[tuple[str, str]]] = {rule.name: set() for rule in RULES}
    if not BASELINE_PATH.is_file():
        return baseline
    for raw_line in BASELINE_PATH.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        check_name, _, rest = line.partition("|")
        rel_path, _, content = rest.partition("|")
        if check_name not in baseline:
            continue
        baseline[check_name].add((rel_path, content))
    return baseline


def main() -> int:
    baseline = load_baseline()
    violations: list[str] = []
    matched_baseline: set[tuple[str, str, str]] = set()

    for path in iter_source_files():
        rel_path = str(path.relative_to(ROOT))
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        # An allow comment may sit on the flagged line itself (a trailing
        # comment) or on the line immediately above it (the same shape as
        # this codebase's `// swiftlint:disable:next` convention, needed for
        # a call whose own line is already long).
        allow_by_line: dict[int, str] = {}
        for line_number, line in enumerate(lines, start=1):
            allow_match = ALLOW_COMMENT_RE.search(line)
            if allow_match:
                allow_by_line[line_number] = allow_match.group(1)

        for line_number, line in enumerate(lines, start=1):
            allowed_checks = {
                allow_by_line.get(line_number),
                allow_by_line.get(line_number - 1),
            }
            # Match only the code portion, not a trailing/whole-line `//`
            # comment — a doc comment that merely *mentions* one of these
            # patterns (e.g. ModelContext+Save.swift's own header explaining
            # the anti-pattern it replaces) is not an instance of it.
            code_part = line.split("//", 1)[0]
            for rule in RULES:
                if not rule.pattern.search(code_part):
                    continue
                if rule.name in allowed_checks:
                    continue
                stripped = line.strip()
                if (rel_path, stripped) in baseline[rule.name]:
                    matched_baseline.add((rule.name, rel_path, stripped))
                    continue
                violations.append(
                    f"::error file={rel_path},line={line_number}::"
                    f"[{rule.name}] {rule.description}"
                )

    stale: list[str] = []
    for rule_name, entries in baseline.items():
        for rel_path, content in sorted(entries):
            if (rule_name, rel_path, content) not in matched_baseline:
                stale.append(
                    f"::error file={BASELINE_PATH.relative_to(ROOT)}::"
                    f"[{rule_name}] stale baseline entry for {rel_path}: the "
                    f"line no longer exists; remove it so the exemption "
                    f"does not outlive the code it covered: {content}"
                )

    for rule in RULES:
        print(f"static policy baseline [{rule.name}]: {len(baseline[rule.name])} baseline entries")

    if violations or stale:
        for violation in violations + stale:
            print(violation)
        print(
            f"\nstatic policy check failed with {len(violations)} new "
            f"violation(s) and {len(stale)} stale baseline entries. Fix "
            "the code, or if this is a deliberate, reviewed exception, add "
            "it to Tools/static_policy_baseline.txt or annotate the line "
            "with `// static-policy:allow <check>`; delete baseline entries "
            "whose line is gone.",
            file=sys.stderr,
        )
        return 1

    print("Static policy check passed: no new violations.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
