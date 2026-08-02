#!/usr/bin/env python3
"""Fetch a small subset of a Hugging Face audio+transcript dataset.

Writes `<name>.audio.<ext>` + `<name>.reference.txt` + `dataset.json` into the
layout `PublicEvaluationDataset` (`KurnTests/Support/Evaluation/`) reads.

Can be imported as a module (`fetch(...)`) or run as a script.

Tolerates three audio shapes from the `datasets` streaming API:
- `{"bytes": b"...", "path": "..."}` -> use bytes directly
- `{"path": "https://..."}`          -> download raw encoded bytes
- `{"array": ndarray, "sampling_rate": int, "path": "..."}`
                                     -> re-encode to PCM WAV

This avoids getting stuck when a corpus (e.g. Common Voice in streaming mode)
does not embed raw bytes in every row.
"""

from __future__ import annotations

import argparse
import io
import json
import re
import sys
import urllib.request
import warnings
import wave
from pathlib import Path


def slugify(text: str, limit: int = 40) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", text.strip()).strip("-").lower()
    return slug[:limit] or "item"


def fetch(entry: dict, out_dir: Path, token: str | None = None) -> None:
    """Fetch one corpus entry into `out_dir`.

    Raises `SystemExit` with an actionable message if the fetch fails.
    """
    try:
        from datasets import Audio, load_dataset
    except ImportError as error:
        raise SystemExit(
            "missing dependency: pip install datasets huggingface_hub "
            "(see Tools/evaluation/public_datasets/README.md)"
        ) from error

    out_dir.mkdir(parents=True, exist_ok=True)

    print(
        f"[fetch] {entry['id']}: loading {entry['hf_dataset']} ({entry.get('hf_config')}) split={entry['hf_split']}",
        flush=True,
    )

    trust_remote_code = entry.get("trust_remote_code")
    # Default to True so older/remote-code datasets keep working, but let the
    # manifest override it (e.g. to False for pure Parquet corpora).
    if trust_remote_code is None:
        trust_remote_code = True

    dataset = load_dataset(
        entry["hf_dataset"],
        entry.get("hf_config"),
        split=entry["hf_split"],
        streaming=True,
        token=token,
        trust_remote_code=trust_remote_code,
    )
    dataset = dataset.cast_column(entry["audio_column"], Audio(decode=False))

    sample_count = int(entry["sample_count"])
    written: list[str] = []
    row_count = 0
    max_rows_to_scan = max(sample_count * 100, 1000)

    for row_count, row in enumerate(dataset, start=1):
        if len(written) >= sample_count:
            break
        if row_count >= max_rows_to_scan:
            warnings.warn(
                f"{entry['id']}: scanned {row_count} rows and only found {len(written)} usable; "
                "stopping to avoid an infinite loop."
            )
            break

        text = (row.get(entry["text_column"]) or "").strip()
        if not text:
            continue

        audio = row[entry["audio_column"]]
        raw, extension = extract_audio_bytes(audio, entry["audio_extension"])
        if raw is None:
            continue

        base = row.get("id") or row.get("path") or entry["id"]
        name = f"{slugify(str(base))}-{len(written):04d}"

        actual_extension = extension or entry["audio_extension"]
        (out_dir / f"{name}.audio.{actual_extension}").write_bytes(raw)
        (out_dir / f"{name}.reference.txt").write_text(text + "\n", encoding="utf-8")
        written.append(name)
        print(f"[fetch] {entry['id']}: wrote {name} ({len(raw)} bytes)", flush=True)

    if not written:
        raise SystemExit(
            f"{entry['id']}: fetched 0 usable rows out of {row_count} scanned.\n"
            "Check hf_dataset/hf_config/hf_split/text_column/audio_column in manifest.json, "
            "and -- for a gated dataset -- that a valid HF token is set and the account has "
            "accepted the dataset's terms on huggingface.co."
        )

    (out_dir / "dataset.json").write_text(
        json.dumps(
            {
                "language": entry["language"],
                "corpus": entry["corpus_name"],
                "license": entry.get("license", ""),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"[fetch] {entry['id']}: wrote {len(written)} item(s) to {out_dir}", flush=True)


def extract_audio_bytes(audio, default_extension: str) -> tuple[bytes | None, str | None]:
    """Return (encoded_audio_bytes, file_extension) for an audio value from datasets.

    Tries several shapes because streaming behaviour varies by corpus and by
    `datasets` version:
      - dict with `bytes` -> return bytes directly
      - dict with `path` that looks like a URL -> download it
      - dict with `array`/`sampling_rate` -> encode to WAV
    """
    if isinstance(audio, dict):
        if audio.get("bytes"):
            return bytes(audio["bytes"]), _extension_from_path(audio.get("path"), default_extension)

        if "array" in audio and "sampling_rate" in audio:
            return _encode_array_to_wav(audio["array"], audio["sampling_rate"]), "wav"

        path = audio.get("path")
        if path:
            url_or_path = str(path)
            if url_or_path.startswith(("http://", "https://")):
                return _download_bytes(url_or_path), _extension_from_path(url_or_path, default_extension)

    if isinstance(audio, bytes):
        return audio, default_extension

    return None, None


def _extension_from_path(path, default: str) -> str:
    if not path:
        return default
    suffix = Path(str(path)).suffix.lower().lstrip(".")
    return suffix if suffix else default


def _download_bytes(url: str, timeout: int = 120) -> bytes | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.read()
    except Exception as error:
        print(f"[fetch] warning: could not download {url}: {error}", file=sys.stderr, flush=True)
        return None


def _encode_array_to_wav(array, sampling_rate: int) -> bytes | None:
    try:
        import numpy as np
    except ImportError as error:
        print(
            f"[fetch] warning: cannot re-encode decoded audio without numpy ({error}); install numpy",
            file=sys.stderr,
            flush=True,
        )
        return None

    try:
        samples = np.asarray(array)
        if samples.dtype.kind == "f":
            samples = np.clip(samples * 32767.0, -32768, 32767).astype(np.int16)
        else:
            samples = samples.astype(np.int16)

        if samples.ndim == 1:
            channels = 1
            samples = samples.reshape(-1)
        else:
            channels = samples.shape[-1]
            samples = samples.reshape(-1)

        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as wav_file:
            wav_file.setnchannels(channels)
            wav_file.setsampwidth(2)
            wav_file.setframerate(sampling_rate)
            wav_file.writeframes(samples.tobytes())
        return buffer.getvalue()
    except Exception as error:
        print(f"[fetch] warning: could not encode audio array to WAV: {error}", file=sys.stderr, flush=True)
        return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest-entry", required=True, type=Path, help="JSON file with one manifest.json corpus entry")
    parser.add_argument("--out", required=True, type=Path, help="output directory for this corpus")
    parser.add_argument("--token", default=None, help="Hugging Face token, for gated datasets")
    args = parser.parse_args()

    entry = json.loads(args.manifest_entry.read_text(encoding="utf-8"))
    fetch(entry, args.out, token=args.token)


if __name__ == "__main__":
    sys.exit(main())
