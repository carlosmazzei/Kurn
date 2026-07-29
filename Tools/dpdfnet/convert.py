#!/usr/bin/env python3
"""Convert a DPDFNet ONNX release to Core ML for the Kurn app.

The script is deliberately *self-describing*: before converting anything it
prints the ONNX graph's real inputs and outputs, and afterwards it writes a JSON
sidecar recording the tensor names and shapes it actually found. The Swift side
reads that sidecar instead of hardcoding them.

That indirection is the point. A model whose tensor layout is assumed rather
than observed still loads, still runs, and still returns plausible-sounding
audio — it is simply wrong, and nothing downstream notices. Discovering the
shapes here turns a silent failure into a printed fact.

Usage:

    python3 -m venv .venv && source .venv/bin/activate
    pip install coremltools onnx numpy
    python3 convert.py --onnx path/to/dpdfnet8_16khz.onnx

Run `--inspect-only` first if you just want to see the graph.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

# Where the app expects the converted artifacts. Relative to the repo root.
BUNDLE_DIR = Path("Kurn/Resources/Models")
# Must match SpeechEnhancerModelConfig.resourceName on the Swift side.
CONFIG_NAME = "dpdfnet"

# DPDFNet inherits DeepFilterNet2's framing: a 20 ms window with a 10 ms hop.
# Written into the sidecar rather than assumed by Swift, and cross-checked
# against the graph's declared bin count below.
FRAME_MS = 20.0
HOP_MS = 10.0


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def describe(model) -> tuple[list, list]:
    """Print and return the graph's inputs and outputs."""
    import onnx  # noqa: F401  (imported for its side effect on the proto types)

    def shape_of(value) -> list:
        dims = []
        for dim in value.type.tensor_type.shape.dim:
            dims.append(dim.dim_value if dim.dim_value > 0 else (dim.dim_param or "?"))
        return dims

    inputs = [(v.name, shape_of(v)) for v in model.graph.input]
    outputs = [(v.name, shape_of(v)) for v in model.graph.output]

    print("\nONNX graph interface")
    print("--------------------")
    for name, shape in inputs:
        print(f"  input   {name:<24} {shape}")
    for name, shape in outputs:
        print(f"  output  {name:<24} {shape}")
    print()
    return inputs, outputs


def pick(entries: list, *, exclude: str | None = None):
    """Heuristic split of (spectrum, state) tensors.

    The spectrum tensor is the one carrying a trailing 2 (real/imaginary); the
    state is whatever else remains. If this guesses wrong the printed interface
    above is the ground truth — pass --spectrum-input etc. to override.
    """
    spectrum = None
    state = None
    for name, shape in entries:
        if exclude and name == exclude:
            continue
        if shape and shape[-1] == 2 and spectrum is None:
            spectrum = (name, shape)
        else:
            state = (name, shape)
    return spectrum, state


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--onnx", required=True, type=Path, help="Path to the DPDFNet ONNX file")
    parser.add_argument("--sample-rate", type=float, default=16_000.0)
    parser.add_argument("--out", type=Path, default=None, help="Output directory (default: %s)" % BUNDLE_DIR)
    parser.add_argument("--model-name", default="DPDFNet")
    parser.add_argument("--inspect-only", action="store_true", help="Print the graph and stop")
    parser.add_argument("--spectrum-input", default=None)
    parser.add_argument("--state-input", default=None)
    parser.add_argument("--spectrum-output", default=None)
    parser.add_argument("--state-output", default=None)
    args = parser.parse_args()

    if not args.onnx.exists():
        print(f"error: {args.onnx} not found", file=sys.stderr)
        return 1

    try:
        import onnx
    except ImportError:
        print("error: pip install onnx coremltools numpy", file=sys.stderr)
        return 1

    print(f"Reading {args.onnx}")
    print(f"  sha256 {sha256(args.onnx)}")
    model = onnx.load(str(args.onnx))
    inputs, outputs = describe(model)

    if args.inspect_only:
        return 0

    spec_in, state_in = pick(inputs)
    spec_out, state_out = pick(outputs)
    names = {
        "spectrumInput": args.spectrum_input or (spec_in[0] if spec_in else None),
        "stateInput": args.state_input or (state_in[0] if state_in else None),
        "spectrumOutput": args.spectrum_output or (spec_out[0] if spec_out else None),
        "stateOutput": args.state_output or (state_out[0] if state_out else None),
    }
    missing = [key for key, value in names.items() if not value]
    if missing:
        print(
            "error: could not identify " + ", ".join(missing) +
            ".\n       Pass them explicitly using the interface printed above, e.g."
            "\n       --spectrum-input spec --state-input state",
            file=sys.stderr,
        )
        return 2

    bin_count = spec_in[1][-2] if spec_in and len(spec_in[1]) >= 2 else None
    state_size = None
    if state_in:
        dims = [d for d in state_in[1] if isinstance(d, int)]
        if dims:
            state_size = 1
            for dim in dims:
                state_size *= dim

    frame_size = int(round(args.sample_rate * FRAME_MS / 1000.0))
    hop_size = int(round(args.sample_rate * HOP_MS / 1000.0))
    expected_bins = frame_size // 2 + 1
    if isinstance(bin_count, int) and bin_count != expected_bins:
        print(
            f"warning: graph declares {bin_count} bins but a {FRAME_MS} ms window at "
            f"{args.sample_rate:.0f} Hz implies {expected_bins}. Trusting the graph; "
            "check the model's framing before shipping.",
            file=sys.stderr,
        )
        frame_size = (bin_count - 1) * 2
        hop_size = frame_size // 2

    try:
        import coremltools as ct
    except ImportError:
        print("error: pip install coremltools", file=sys.stderr)
        return 1

    out_dir = args.out or BUNDLE_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    package_path = out_dir / f"{args.model_name}.mlpackage"

    print(f"Converting to {package_path} …")
    # fp16 weights, ML Program, iOS 16 floor. The recurrent state stays a plain
    # input/output pair rather than an iOS 18 `StateType`: more portable, and far
    # simpler to drive frame by frame from Swift.
    mlmodel = ct.convert(
        model,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.save(str(package_path))

    print("\nCore ML interface")
    print("-----------------")
    print(mlmodel.get_spec().description)

    config = {
        "modelName": args.model_name,
        "sampleRate": args.sample_rate,
        "frameSize": frame_size,
        "hopSize": hop_size,
        "binCount": bin_count if isinstance(bin_count, int) else expected_bins,
        "stateSize": state_size or 0,
        **names,
    }
    config_path = out_dir / f"{CONFIG_NAME}.json"
    config_path.write_text(json.dumps(config, indent=2) + "\n")

    print(f"\nWrote {package_path}")
    print(f"Wrote {config_path}")
    print("\nNext: add both to the Kurn target in Xcode (file-system-synchronized")
    print("groups pick up new files automatically, but resources still need to be")
    print("in the target's Copy Bundle Resources phase), then rebuild.")
    if not config["stateSize"]:
        print(
            "\nwarning: the recurrent state size could not be determined from the "
            "graph (dynamic dimension). Fill stateSize in the JSON by hand from the "
            "interface printed above.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
