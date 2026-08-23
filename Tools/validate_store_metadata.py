#!/usr/bin/env python3

from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
METADATA = ROOT / "fastlane" / "metadata"
LOCALES = {"de-DE", "en-US", "es-ES", "fr-FR", "it", "pt-BR", "zh-Hans"}
NON_LOCALE_DIRECTORIES = {"review_information"}
LIMITS = {
    "description.txt": (1, 4000, "characters"),
    "keywords.txt": (1, 100, "bytes"),
    "name.txt": (2, 30, "characters"),
    "promotional_text.txt": (1, 170, "characters"),
    "release_notes.txt": (1, 4000, "characters"),
    "subtitle.txt": (1, 30, "characters"),
}
URL_FILES = {"marketing_url.txt", "privacy_url.txt", "support_url.txt"}
ROOT_FILES = {"copyright.txt", "primary_category.txt"}

errors = []


def report(path: Path, message: str) -> None:
    relative = path.relative_to(ROOT)
    errors.append(f"{relative}: {message}")
    print(f"::error file={relative}::{message}")


actual_locales = {
    path.name
    for path in METADATA.iterdir()
    if path.is_dir() and path.name not in NON_LOCALE_DIRECTORIES
}
if actual_locales != LOCALES:
    missing = sorted(LOCALES - actual_locales)
    unexpected = sorted(actual_locales - LOCALES)
    report(METADATA, f"locale mismatch; missing={missing}, unexpected={unexpected}")

for filename in ROOT_FILES:
    path = METADATA / filename
    if not path.is_file() or not path.read_text(encoding="utf-8").strip():
        report(path, "required metadata is missing or empty")

for locale in sorted(LOCALES):
    directory = METADATA / locale
    for filename, (minimum, maximum, unit) in LIMITS.items():
        path = directory / filename
        if not path.is_file():
            report(path, "required metadata file is missing")
            continue
        value = path.read_text(encoding="utf-8").strip()
        size = len(value.encode("utf-8")) if unit == "bytes" else len(value)
        if not minimum <= size <= maximum:
            report(path, f"must contain {minimum}-{maximum} {unit}; found {size}")

    for filename in URL_FILES:
        path = directory / filename
        if not path.is_file():
            report(path, "required URL file is missing")
            continue
        value = path.read_text(encoding="utf-8").strip()
        parsed = urlparse(value)
        if parsed.scheme != "https" or not parsed.netloc:
            report(path, "must contain a valid HTTPS URL")

if errors:
    raise SystemExit(f"App Store metadata validation failed with {len(errors)} error(s).")

print(f"Validated App Store metadata for {len(LOCALES)} locales.")
