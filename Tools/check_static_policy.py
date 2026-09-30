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
# Three further rules keep the layer boundaries CLAUDE.md describes from
# eroding one convenient reference at a time (the architecture inspection
# found `RecordingLauncher` building a view model, a view model building a
# View-declared type, and eight Views mutating the store directly):
#
# - upward-dependency: code in Models/, Providers/, Services/,
#   Infrastructure/, Application/ or AppIntents/ must not name a type
#   declared in ViewModels/ or Views/, and code in ViewModels/ must not name
#   a type declared in Views/. The set of names is derived from the
#   declarations themselves on every run, so a new view model or View is
#   covered without editing this file.
# - view-store-mutation: a View must not insert into or delete from a
#   `ModelContext`; library mutations go through `MeetingLibrary`
#   (Application/), and pipeline output through its coordinator.
# - view-keychain: a View must not reach `KeychainManager`; key status and
#   writes go through the observable `CredentialStore`.
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
    # Repo-relative directory prefixes the rule applies to; empty = everywhere.
    scope: tuple[str, ...] = ()

    def applies_to(self, rel_path: str) -> bool:
        return not self.scope or rel_path.startswith(self.scope)


VIEWS_DIR = "Kurn/Views/"
VIEW_MODELS_DIR = "Kurn/ViewModels/"
# Layers that must not depend on view models or Views.
LOWER_LAYER_DIRS = (
    "Kurn/Models/",
    "Kurn/Providers/",
    "Kurn/Services/",
    "Kurn/Infrastructure/",
    "Kurn/Application/",
    "Kurn/AppIntents/",
)

# A top-level-or-nested type declaration: attributes and modifiers, then the
# kind keyword and the name. `private`/`fileprivate` declarations are
# excluded by the caller, since they cannot be named from another file.
TYPE_DECLARATION_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"((?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*)"
    r"(?:class|struct|enum|actor|protocol)\s+([A-Z]\w*)"
)
STRING_LITERAL_RE = re.compile(r'"(?:[^"\\]|\\.)*"')


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
    Rule(
        name="view-store-mutation",
        pattern=re.compile(r"\b\w*[cC]ontext\s*\.\s*(?:insert|delete)\s*\("),
        description=(
            "a View inserting into or deleting from a ModelContext. Library "
            "mutations belong in MeetingLibrary (Kurn/Application/), which "
            "owns their rules (name deduplication, journaled file cleanup) "
            "and surfaces save failures as AppError."
        ),
        scope=(VIEWS_DIR,),
    ),
    Rule(
        name="view-keychain",
        pattern=re.compile(r"\bKeychainManager\b"),
        description=(
            "a View reaching the Keychain directly. Read key status and "
            "write keys through `settings.credentials` (CredentialStore), "
            "which is observable and keeps the provider selections valid."
        ),
        scope=(VIEWS_DIR,),
    ),
]

UPWARD_DEPENDENCY = "upward-dependency"
UPWARD_DEPENDENCY_DESCRIPTION = (
    "a lower layer naming a type declared in a higher one ({name}, declared "
    "in {declared_in}). Models/Providers/Services/Infrastructure/Application/"
    "AppIntents must not depend on ViewModels/ or Views/, and ViewModels/ "
    "must not depend on Views/. Move the shared type down, or invert the "
    "dependency (pass a closure or a protocol in from the higher layer)."
)

RULES_BY_NAME = {rule.name: rule for rule in RULES}
BASELINE_CHECKS = [rule.name for rule in RULES] + [UPWARD_DEPENDENCY]


def declared_types(directory: str) -> dict[str, str]:
    """Type name -> repo-relative file, for every non-private type
    declared under `directory`."""
    names: dict[str, str] = {}
    root = ROOT / directory
    if not root.is_dir():
        return names
    for path in sorted(root.rglob("*.swift")):
        for line in path.read_text(encoding="utf-8").splitlines():
            match = TYPE_DECLARATION_RE.match(line)
            if not match or "private" in match.group(1):
                continue
            names.setdefault(match.group(2), str(path.relative_to(ROOT)))
    return names


def names_pattern(names: dict[str, str]) -> re.Pattern[str] | None:
    if not names:
        return None
    alternatives = "|".join(sorted(map(re.escape, names), key=len, reverse=True))
    return re.compile(rf"\b({alternatives})\b")


def upward_dependency_targets() -> list[tuple[tuple[str, ...], dict[str, str], re.Pattern[str] | None]]:
    """(scanned directories, forbidden names, pattern) pairs."""
    view_types = declared_types(VIEWS_DIR)
    upper_types = {**declared_types(VIEW_MODELS_DIR), **view_types}
    return [
        (LOWER_LAYER_DIRS, upper_types, names_pattern(upper_types)),
        ((VIEW_MODELS_DIR,), view_types, names_pattern(view_types)),
    ]


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
    baseline: dict[str, set[tuple[str, str]]] = {name: set() for name in BASELINE_CHECKS}
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
    layer_targets = upward_dependency_targets()

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
            stripped = line.strip()

            def report(check: str, description: str) -> None:
                if check in allowed_checks:
                    return
                if (rel_path, stripped) in baseline[check]:
                    matched_baseline.add((check, rel_path, stripped))
                    return
                violations.append(
                    f"::error file={rel_path},line={line_number}::"
                    f"[{check}] {description}"
                )

            for rule in RULES:
                if rule.applies_to(rel_path) and rule.pattern.search(code_part):
                    report(rule.name, rule.description)

            # Names inside string literals (log text, identifiers) are not
            # dependencies, so they are blanked before this match only.
            code_without_strings = STRING_LITERAL_RE.sub('""', code_part)
            for directories, names, pattern in layer_targets:
                if pattern is None or not rel_path.startswith(directories):
                    continue
                match = pattern.search(code_without_strings)
                if match:
                    report(UPWARD_DEPENDENCY, UPWARD_DEPENDENCY_DESCRIPTION.format(
                        name=match.group(1), declared_in=names[match.group(1)]
                    ))

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

    for check in BASELINE_CHECKS:
        print(f"static policy baseline [{check}]: {len(baseline[check])} baseline entries")

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
