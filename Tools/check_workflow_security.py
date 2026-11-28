#!/usr/bin/env python3
#
# Keeps the repository's secrets where they belong. Kurn is public and open source, so anyone can open a
# pull request and anyone with write access can edit a workflow, and a workflow that names a secret can
# read it. Two things stop that from costing money or reaching App Store Connect:
#
# - a secret that can spend money (an API key) or ship the app lives in a protected GitHub environment,
#   which releases it only to a job that names the environment, only after its reviewer approves and only
#   from the branches the environment allows. `paid-evals` holds the AI provider keys and the Hugging Face
#   token; `release` holds the App Store Connect and fastlane match secrets.
# - nothing that runs untrusted code (a pull request, an issue comment, another workflow's artifacts) is
#   triggered where secrets are reachable.
#
# This check makes the workflows say so, so a new workflow or a new secret cannot quietly bypass it:
#
# - every secret a job reads is classified here (paid, release or free), and a job that reads a paid or
#   release secret declares that secret's environment (or, in an expression, that one and a listed
#   secretless environment);
# - a workflow with a paid secret is `workflow_dispatch` only: no push, pull request or schedule spends
#   money unattended;
# - no workflow uses a trigger that runs with secrets on content an outsider controls
#   (`pull_request_target`, `workflow_run`, comments, issues, reviews, discussions);
# - no `secrets: inherit` and no dynamically indexed `secrets[...]`;
# - `.github/CODEOWNERS` exists and names an owner for `.github/`, so a change to a workflow needs its
#   owner's review once the ruleset asks for code-owner review.
#
# It reads the workflow text line by line (the files are consistently formatted and the repository has no
# YAML dependency to install). It cannot tell that an environment is configured with reviewers: that is a
# repository setting, described in CLAUDE.md "CI supply chain".

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PAID_ENVIRONMENT = "paid-evals"
RELEASE_ENVIRONMENT = "release"
# Environments that hold no secrets and no restriction. A job that needs a paid secret may name one of these
# beside the paid environment in an expression, for a run that sends nothing to a provider (pipeline-eval's
# keyless on-device run). It is only safe while no paid secret is left at repository level: the repository's
# own secrets reach every environment.
SECRETLESS_ENVIRONMENTS = {"evals-open"}

PAID_SECRETS = {
    "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GROQ_API_KEY", "ELEVENLABS_API_KEY", "HF_TOKEN",
}
RELEASE_SECRETS = {
    "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_CONTENT",
    "MATCH_PASSWORD", "MATCH_GIT_URL", "MATCH_GIT_BASIC_AUTHORIZATION",
}
# Cannot spend money or ship the app: the repository's own token and the coverage upload token.
FREE_SECRETS = {"GITHUB_TOKEN", "CODECOV_TOKEN"}

FORBIDDEN_TRIGGERS = {
    "pull_request_target", "workflow_run", "issue_comment", "issues", "pull_request_review",
    "pull_request_review_comment", "discussion", "discussion_comment",
}

# `secrets: inherit` hands a called workflow every repository secret, so it is refused unless a job is listed
# here with the reason. `swift.yml`'s `store-assets` calls screenshots.yml, whose only job that reads a secret
# (`upload`) declares `environment: release`; the capture jobs read none. Naming the secrets explicitly
# instead waits until the App Store Connect secrets are known to be environment secrets of `release`, because
# changing how a release-tag run receives them cannot be tested outside a release.
INHERIT_EXCEPTIONS = {
    ("swift.yml", "store-assets"): "the called screenshots.yml reads secrets only in its `release` environment job",
}

SECRET_REFERENCE = re.compile(r"secrets\.([A-Za-z0-9_]+)")


@dataclass
class Job:
    name: str
    lines: list[str] = field(default_factory=list)

    @property
    def environments(self) -> set[str]:
        """Every environment the job can run in: its name, or each quoted result of an `${{ }}` expression."""
        value = self.environment
        if value is None:
            return set()
        if "${{" in value:
            # The quoted results of the expression, not the values it compares an input with.
            results = re.sub(r"(==|!=)\s*'[^']*'", "", value)
            return set(re.findall(r"'([A-Za-z0-9_.-]+)'", results))
        return {value}

    @property
    def environment(self) -> str | None:
        """The job's own `environment:` text, as a name, an expression or a `name:` mapping."""
        for index, line in enumerate(self.lines):
            match = re.match(r"^    environment:\s*(.*?)\s*$", line)
            if not match:
                continue
            value = match.group(1)
            if value:
                return value.strip("'\"")
            for follower in self.lines[index + 1:]:
                inner = re.match(r"^      name:\s*(\S+)\s*$", follower)
                if inner:
                    return inner.group(1).strip("'\"")
                if follower.strip() and not follower.startswith("      "):
                    break
            return None
        return None

    @property
    def secrets(self) -> set[str]:
        return {name for line in self.lines for name in SECRET_REFERENCE.findall(line)}


def content_lines(text: str) -> list[str]:
    """The file's lines without whole-line comments (an inline comment is kept, which only errs towards a finding)."""
    return [line for line in text.splitlines() if not line.lstrip().startswith("#")]


def triggers(lines: list[str]) -> set[str] | None:
    """The event names under a block-style top-level `on:`, or None when it is written another way."""
    for index, line in enumerate(lines):
        if re.match(r"^(on|\"on\"|'on'):\s*$", line):
            names: set[str] = set()
            for follower in lines[index + 1:]:
                if follower.strip() and not follower.startswith(" "):
                    break
                match = re.match(r"^  ([A-Za-z_]+):", follower)
                if match:
                    names.add(match.group(1))
            return names
        if re.match(r"^(on|\"on\"|'on'):", line):
            return None
    return set()


def jobs(lines: list[str]) -> list[Job]:
    found: list[Job] = []
    in_jobs = False
    for line in lines:
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True
            continue
        if not in_jobs:
            continue
        if line.strip() and not line.startswith(" "):
            in_jobs = False
            continue
        header = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if header:
            found.append(Job(header.group(1)))
        elif found:
            found[-1].lines.append(line)
    return found


def check_workflow(path: Path, relative: str) -> list[str]:
    findings: list[str] = []
    lines = content_lines(path.read_text(encoding="utf-8"))
    events = triggers(lines)
    if events is None:
        findings.append(f"{relative}: `on:` must be a block (one event per line) so its triggers can be checked")
        events = set()
    for event in sorted(events & FORBIDDEN_TRIGGERS):
        findings.append(f"{relative}: trigger `{event}` runs with secrets on content an outsider controls")
    if any("secrets[" in line for line in lines):
        findings.append(f"{relative}: `secrets[...]` is read dynamically, so it cannot be classified")
    has_paid = False
    for job in jobs(lines):
        environments = job.environments
        if any(re.search(r"secrets:\s*inherit", line) for line in job.lines) \
                and (path.name, job.name) not in INHERIT_EXCEPTIONS:
            findings.append(f"{relative}: job `{job.name}` uses `secrets: inherit`, which hands the called workflow "
                            "every secret; pass the ones it needs")
        for secret in sorted(job.secrets):
            if secret in FREE_SECRETS:
                continue
            if secret in PAID_SECRETS:
                has_paid = True
                needed = PAID_ENVIRONMENT
            elif secret in RELEASE_SECRETS:
                needed = RELEASE_ENVIRONMENT
            else:
                findings.append(f"{relative}: job `{job.name}` reads `{secret}`, which Tools/check_workflow_security.py "
                                "does not classify (paid, release or free)")
                continue
            others = environments - {needed}
            if needed not in environments or (others and not others <= SECRETLESS_ENVIRONMENTS):
                findings.append(f"{relative}: job `{job.name}` reads `{secret}` and must declare `environment: {needed}`"
                                f" (it declares {', '.join(sorted(environments)) or 'none'})")
    if has_paid and events != {"workflow_dispatch"}:
        findings.append(f"{relative}: a workflow with a paid secret must be `workflow_dispatch` only (it has "
                        f"{', '.join(sorted(events)) or 'no triggers'})")
    return findings


def check_actions(root: Path) -> list[str]:
    findings: list[str] = []
    for path in sorted((root / ".github" / "actions").glob("**/action.yml")):
        relative = str(path.relative_to(root))
        for line in content_lines(path.read_text(encoding="utf-8")):
            for secret in SECRET_REFERENCE.findall(line):
                if secret not in FREE_SECRETS:
                    findings.append(f"{relative}: reads `{secret}`; a composite action takes secrets as inputs")
    return findings


def check_codeowners(root: Path) -> list[str]:
    path = root / ".github" / "CODEOWNERS"
    if not path.exists():
        return [".github/CODEOWNERS: missing; workflow changes need a named owner"]
    entries = [line.split() for line in path.read_text(encoding="utf-8").splitlines()
               if line.strip() and not line.lstrip().startswith("#")]
    if not any(parts[0] in ("/.github/", "/.github") and len(parts) > 1 for parts in entries):
        return [".github/CODEOWNERS: no owner for /.github/"]
    return []


def check(root: Path = ROOT) -> list[str]:
    findings: list[str] = []
    for path in sorted((root / ".github" / "workflows").glob("*.yml")):
        findings.extend(check_workflow(path, str(path.relative_to(root))))
    findings.extend(check_actions(root))
    findings.extend(check_codeowners(root))
    return findings


def main() -> int:
    findings = check()
    for finding in findings:
        print(f"workflow-security: {finding}")
    if findings:
        print(f"Workflow security check failed: {len(findings)} finding(s).")
        return 1
    print("Workflow security check passed: every secret is in its environment, no unsafe trigger.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
