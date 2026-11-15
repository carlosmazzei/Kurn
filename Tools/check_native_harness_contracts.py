#!/usr/bin/env python3
"""Validate NH01 traceability and frozen characterization data without running providers."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

CATALOG = "docs/contracts/native-harness-v1.json"
PROFILE = {
    "appOnly": True, "backend": False, "externalExtensions": False,
    "sourceSelection": True, "saveConversationArtifacts": True,
}
STATUSES = {"pending", "partial", "conditional", "excluded", "verified"}
DISPOSITIONS = {"required", "adapted", "conditional", "excluded"}


def read_json(path: Path) -> dict:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def validate(root: Path, manifest: dict | None = None) -> list[str]:
    root = root.resolve()
    errors: list[str] = []
    try:
        manifest = read_json(root / CATALOG) if manifest is None else manifest
    except (OSError, ValueError) as error:
        return [f"{CATALOG}: {error}"]
    if not isinstance(manifest, dict):
        return ["contract catalog must be an object"]
    for key in ("manifestVersion", "contractVersion"):
        if type(manifest.get(key)) is not int or manifest[key] != 1:
            errors.append(f"unsupported {key}; expected integer 1")
    profile = manifest.get("profileConstraints")
    if profile != PROFILE or not isinstance(profile, dict) or any(type(value) is not bool for value in profile.values()):
        errors.append("app-only, source selection and document constraints must match contract v1")
    baseline = manifest.get("baselineCommit", "")
    reference = manifest.get("specReference")
    revision = reference.get("piRevision", "") if isinstance(reference, dict) else ""
    if not isinstance(baseline, str) or re.fullmatch(r"[0-9a-f]{40}", baseline) is None:
        errors.append("baselineCommit must be a full commit SHA")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        errors.append("specReference.piRevision must be a full commit SHA")

    def local_file(value, label):
        if not isinstance(value, str) or not value or Path(value).is_absolute() or ".." in Path(value).parts:
            errors.append(f"{label}: expected a repository-relative file")
            return None
        path = (root / value).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            errors.append(f"{label}: missing or out-of-repository file {value}")
            return None
        return path

    def evidence(records, label):
        if not isinstance(records, list):
            errors.append(f"{label}: expected evidence array")
            return
        for item in records:
            if not isinstance(item, dict):
                errors.append(f"{label}: invalid evidence item")
                continue
            path = local_file(item.get("path"), label)
            symbol = item.get("symbol")
            if symbol is not None:
                if not isinstance(symbol, str) or re.fullmatch(r"[A-Za-z_]\w*", symbol) is None:
                    errors.append(f"{label}: invalid test symbol")
                elif path and re.search(r"\b(?:func|def)\s+" + re.escape(symbol) + r"\s*\(", path.read_text(encoding="utf-8")) is None:
                    errors.append(f"{label}: missing test symbol {symbol}")

    local_file(manifest.get("contractDocument"), "contractDocument")
    for collection, prefix, count in (("components", "C", 27), ("acceptance", "A", 70)):
        records = manifest.get(collection)
        if not isinstance(records, list):
            errors.append(f"{collection}: expected array")
            continue
        ids = [item["id"] for item in records if isinstance(item, dict) and isinstance(item.get("id"), str)]
        expected = {f"{prefix}{number:02}" for number in range(1, count + 1)}
        if len(ids) != count or len(set(ids)) != count or set(ids) != expected:
            errors.append(f"{collection}: require each {prefix}01–{prefix}{count:02} exactly once")
        for item in records:
            if not isinstance(item, dict):
                errors.append(f"{collection}: invalid record")
                continue
            label = item.get("id", collection)
            if not isinstance(label, str):
                errors.append(f"{collection}: invalid case ID")
                continue
            disposition, status = item.get("disposition"), item.get("targetStatus")
            if not isinstance(disposition, str) or not isinstance(status, str) or disposition not in DISPOSITIONS or status not in STATUSES:
                errors.append(f"{label}: invalid disposition or targetStatus")
                continue
            if not isinstance(item.get("note"), str) or not item["note"].strip():
                errors.append(f"{label}: explanation required")
            if disposition == "excluded":
                if status != "excluded" or item.get("increment") is not None or item.get("targetEvidence"):
                    errors.append(f"{label}: excluded contracts cannot claim implementation/evidence")
            elif item.get("increment") not in {f"NH{number:02}" for number in range(11)}:
                errors.append(f"{label}: invalid implementation increment")
            if status == "verified" and not item.get("targetEvidence"):
                errors.append(f"{label}: verified target needs target evidence, not only legacy evidence")
            if status == "partial" and not (item.get("baselineEvidence") or item.get("targetEvidence")):
                errors.append(f"{label}: partial status needs baseline or target evidence")
            evidence(item.get("baselineEvidence"), f"{label}.baselineEvidence")
            evidence(item.get("targetEvidence"), f"{label}.targetEvidence")
            if label in {"C20", "C21", "C22", "C23", "C27"} and disposition != "excluded":
                errors.append(f"{label}: external/virtual model subsystem is excluded from v1")

    native = manifest.get("nativeCases", [])
    if not isinstance(native, list):
        errors.append("nativeCases: expected array")
        native = []
    ids = [item["id"] for item in native if isinstance(item, dict) and isinstance(item.get("id"), str)]
    if not ids or len(ids) != len(set(ids)):
        errors.append("nativeCases: unique native case IDs required")
    for item in native:
        if not isinstance(item, dict) or item.get("status") != "characterized" or not item.get("evidence"):
            errors.append("nativeCases: characterization evidence required")
            continue
        evidence(item["evidence"], item["id"])

    fixtures = manifest.get("fixtures", [])
    if not isinstance(fixtures, list) or not fixtures:
        errors.append("frozen characterization fixtures required")
        fixtures = []
    for fixture in fixtures:
        if not isinstance(fixture, dict):
            errors.append("invalid fixture record")
            continue
        label = fixture.get("id", "fixture")
        path = local_file(fixture.get("path"), str(label))
        evidence([fixture.get("consumer")], f"{label}.consumer")
        if path:
            if hashlib.sha256(path.read_bytes()).hexdigest() != fixture.get("sha256"):
                errors.append(f"{label}: frozen fixture checksum changed; review and version intentionally")
            try:
                payload = read_json(path)
                if type(payload.get("fixtureVersion")) is not int or payload["fixtureVersion"] != 1:
                    errors.append(f"{label}: unsupported fixture version")
                if payload.get("baselineCommit") != baseline:
                    errors.append(f"{label}: fixture baseline does not match catalog")
            except (OSError, ValueError) as error:
                errors.append(f"{label}: {error}")
    contracts = manifest.get("contractFixtures", [])
    if not isinstance(contracts, list):
        errors.append("contractFixtures: expected array")
        contracts = []
    for fixture in contracts:
        if not isinstance(fixture, dict):
            errors.append("invalid contract fixture record")
            continue
        label = fixture.get("id", "contract fixture")
        path = local_file(fixture.get("path"), str(label))
        evidence([fixture.get("consumer")], f"{label}.consumer")
        if path:
            if hashlib.sha256(path.read_bytes()).hexdigest() != fixture.get("sha256"):
                errors.append(f"{label}: contract fixture checksum changed; review and version intentionally")
            try:
                payload = read_json(path)
                if any(type(payload.get(key)) is not int or payload[key] != 1 for key in ("fixtureVersion", "contractVersion")):
                    errors.append(f"{label}: unsupported contract fixture version")
                if "baselineCommit" in payload:
                    errors.append(f"{label}: native contract fixtures cannot claim a legacy baseline")
            except (OSError, ValueError) as error:
                errors.append(f"{label}: {error}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    errors = validate(parser.parse_args().root)
    for error in errors:
        print(f"Native harness contract: {error}")
    if not errors:
        print("Native harness v1: 27 components, 70 acceptance cases and frozen fixture evidence validated.")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
