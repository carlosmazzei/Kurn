#!/usr/bin/env python3
"""Static checks for fastlane/metadata before a release tag can upload it.

Two kinds of rule live here. Apple's hard limits (field sizes, required
files, HTTPS URLs) — a violation is a rejected upload. And the App Store
search rules the listing is written against, which Apple does not reject
but which silently waste the only fields search indexes:

- the title, subtitle and keyword field of one localization are indexed
  together, so a keyword repeating a word already in the name or subtitle
  spends bytes on nothing;
- the app name, category names and duplicates are indexed already or twice;
- keywords are one comma-separated list with no spaces around the commas;
- other apps' names are not allowed in metadata (App Review Guideline
  2.3.7), however much search traffic they carry.

Each localization directory is a store language. Which storefront shows
which language is Apple's table ("App Store localizations" in App Store
Connect Help): English (U.K.) is the default or the extra language of most
storefronts, Spanish (Mexico) of Latin America and the United States, so
those directories exist even though the app's UI has one English and one
Spanish localization. Only languages the app's UI is translated into are
listed; a store page in a language the app does not speak would mislead.
"""

import re
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
METADATA = ROOT / "fastlane" / "metadata"
LOCALES = {
    "de-DE",
    "en-AU",
    "en-CA",
    "en-GB",
    "en-US",
    "es-ES",
    "es-MX",
    "fr-CA",
    "fr-FR",
    "it",
    "pt-BR",
    "pt-PT",
    "zh-Hans",
}
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
ROOT_FILES = {"copyright.txt", "primary_category.txt", "secondary_category.txt"}
APP_NAME = "kurn"
# Indexed for every app in the category already.
CATEGORY_WORDS = {"productivity", "business", "app", "iphone", "ipad"}
# Competing apps (Guideline 2.3.7). Matched as whole words, case-insensitive;
# only names that are not also everyday words, so prose never trips it.
COMPETITOR_NAMES = {
    "otter",
    "otterai",
    "plaud",
    "notta",
    "fireflies",
    "granola",
    "twinmind",
    "bluedot",
    "speakwise",
    "tldv",
    "trint",
}
WORD = re.compile(r"[^\W_]+", re.UNICODE)
CJK = re.compile(r"[぀-ヿ㐀-䶿一-鿿가-힯]")


def words(text: str) -> set:
    return {match.group(0).casefold() for match in WORD.finditer(text)}


def keyword_problems(keywords: str, name: str, subtitle: str) -> list:
    """Search-hygiene problems in one localization's keyword field."""
    problems = []
    entries = keywords.split(",")
    if any(entry != entry.strip() for entry in entries):
        problems.append("keywords must not have spaces around commas")
    entries = [entry.strip() for entry in entries]
    if any(not entry for entry in entries):
        problems.append("keywords contain an empty entry")
    seen = set()
    indexed_words = words(name) | words(subtitle)
    indexed_text = (name + subtitle).casefold()
    for entry in filter(None, entries):
        folded = entry.casefold()
        if folded in seen:
            problems.append(f"keyword '{entry}' is repeated")
        seen.add(folded)
        if APP_NAME in words(folded):
            problems.append(f"keyword '{entry}' repeats the app name, which is indexed already")
        if words(folded) & CATEGORY_WORDS:
            problems.append(f"keyword '{entry}' is a category or platform word, which is indexed already")
        duplicated = folded in indexed_text if CJK.search(folded) else words(folded) <= indexed_words
        if duplicated:
            problems.append(f"keyword '{entry}' is already in the name or subtitle")
    return problems


def competitor_problems(text: str) -> list:
    found = sorted(words(text) & COMPETITOR_NAMES)
    return [f"mentions another app ({', '.join(found)}); Guideline 2.3.7"] if found else []


def validate(metadata: Path, locales: set = LOCALES) -> list:
    errors = []

    def report(path: Path, message: str) -> None:
        try:
            shown = path.relative_to(ROOT)
        except ValueError:
            shown = path
        errors.append(f"{shown}: {message}")
        print(f"::error file={shown}::{message}")

    actual_locales = {
        path.name
        for path in metadata.iterdir()
        if path.is_dir() and path.name not in NON_LOCALE_DIRECTORIES
    }
    if actual_locales != locales:
        missing = sorted(locales - actual_locales)
        unexpected = sorted(actual_locales - locales)
        report(metadata, f"locale mismatch; missing={missing}, unexpected={unexpected}")

    for filename in sorted(ROOT_FILES):
        path = metadata / filename
        if not path.is_file() or not path.read_text(encoding="utf-8").strip():
            report(path, "required metadata is missing or empty")
    primary = metadata / "primary_category.txt"
    secondary = metadata / "secondary_category.txt"
    if primary.is_file() and secondary.is_file():
        if primary.read_text(encoding="utf-8").strip() == secondary.read_text(encoding="utf-8").strip():
            report(secondary, "secondary category must differ from the primary one")

    for locale in sorted(locales & actual_locales):
        directory = metadata / locale
        values = {}
        for filename, (minimum, maximum, unit) in LIMITS.items():
            path = directory / filename
            if not path.is_file():
                report(path, "required metadata file is missing")
                continue
            value = path.read_text(encoding="utf-8").strip()
            values[filename] = value
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

        name = values.get("name.txt", "")
        subtitle = values.get("subtitle.txt", "")
        if APP_NAME not in words(name):
            report(directory / "name.txt", "name must keep the app's brand name")
        if subtitle and words(subtitle) <= words(name):
            report(directory / "subtitle.txt", "subtitle only repeats the name")
        if "keywords.txt" in values:
            for problem in keyword_problems(values["keywords.txt"], name, subtitle):
                report(directory / "keywords.txt", problem)
        for filename in ("name.txt", "subtitle.txt", "keywords.txt", "promotional_text.txt", "description.txt"):
            for problem in competitor_problems(values.get(filename, "")):
                report(directory / filename, problem)

    return errors


def main() -> int:
    errors = validate(METADATA)
    if errors:
        print(f"App Store metadata validation failed with {len(errors)} error(s).")
        return 1
    print(f"Validated App Store metadata for {len(LOCALES)} locales.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
