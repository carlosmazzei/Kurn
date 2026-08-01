#!/usr/bin/env python3
"""Convert the official streaming GTCRN model to Core ML for Kurn.

The official repository supplies PyTorch weights and an ONNX streaming graph.
This script builds the same streaming module from source, proves its outputs and
three recurrent caches match ONNX Runtime, converts it to an fp16 ML Program,
then proves Core ML stays numerically close before writing the JSON interface
consumed by SpeechEnhancer.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np

BUNDLE_DIR = Path(__file__).resolve().parents[2] / "Kurn/Resources/Models"
MODEL_NAME = "GTCRN"
CONFIG_NAME = "gtcrn"
SAMPLE_RATE = 16_000.0
FRAME_SIZE = 512
HOP_SIZE = 256
BIN_COUNT = 257
INPUT_NAMES = ["mix", "conv_cache", "tra_cache", "inter_cache"]
OUTPUT_NAMES = ["enh", "conv_cache_out", "tra_cache_out", "inter_cache_out"]
INPUT_SHAPES = [
    (1, 257, 1, 2),
    (2, 1, 16, 16, 33),
    (2, 3, 1, 1, 16),
    (2, 1, 33, 16),
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def import_official_model(source: Path):
    stream_dir = source / "stream"
    checkpoint = stream_dir / "onnx_models/model_trained_on_dns3.tar"
    reference = stream_dir / "onnx_models/gtcrn_simple.onnx"
    for path in (stream_dir, checkpoint, reference):
        if not path.exists():
            raise FileNotFoundError(f"official GTCRN source is incomplete: {path}")

    sys.path.insert(0, str(stream_dir))
    import torch
    import gtcrn_stream as streaming
    from gtcrn import GTCRN
    from modules.convert import convert_to_stream

    # The source graph uses runtime shape reads and mutates cache slices. Both
    # are useful for ONNX export but make Core ML's TorchScript frontend emit
    # dynamic int/copy operations for a graph whose shapes are fixed. These
    # equivalent forwards express the fixed one-frame streaming contract without
    # changing weights or arithmetic; ONNX parity below guards that claim.
    def sfe_forward(self, value):
        return self.unfold(value).unsqueeze(2)

    def shuffle(self, first, second):
        return torch.flatten(
            torch.stack([first, second], dim=1).transpose(1, 2), 1, 2
        )

    def block_forward(self, value, conv_cache, tra_cache):
        first, second = torch.chunk(value, 2, dim=1)
        first = self.sfe(first)
        hidden = self.point_act(self.point_bn1(self.point_conv1(first)))
        hidden, conv_cache = self.depth_conv(hidden, conv_cache)
        hidden = self.depth_act(self.depth_bn(hidden))
        hidden = self.point_bn2(self.point_conv2(hidden))
        hidden, tra_cache = self.tra(hidden, tra_cache)
        return self.shuffle(hidden, second), conv_cache, tra_cache

    def grnn_forward(self, value, hidden=None):
        if hidden is None:
            directions = 2 if self.bidirectional else 1
            hidden = value.new_zeros((self.num_layers * directions, 1, self.hidden_size))
        first, second = torch.chunk(value, 2, dim=-1)
        hidden_first, hidden_second = torch.chunk(hidden, 2, dim=-1)
        out_first, hidden_first = self.rnn1(first, hidden_first.contiguous())
        out_second, hidden_second = self.rnn2(second, hidden_second.contiguous())
        return (
            torch.cat([out_first, out_second], dim=-1),
            torch.cat([hidden_first, hidden_second], dim=-1),
        )

    def dpgrnn_forward(self, value, inter_cache):
        value = value.permute(0, 2, 3, 1)
        intra = value.reshape(-1, self.width, self.input_size)
        intra = self.intra_rnn(intra)[0]
        intra = self.intra_fc(intra).reshape(1, 1, self.width, self.hidden_size)
        intra_out = value + self.intra_ln(intra)

        inter = intra_out.permute(0, 2, 1, 3).reshape(-1, 1, self.input_size)
        inter, inter_cache = self.inter_rnn(inter, inter_cache)
        inter = self.inter_fc(inter).reshape(1, self.width, 1, self.hidden_size)
        inter = self.inter_ln(inter.permute(0, 2, 1, 3))
        return (intra_out + inter).permute(0, 3, 1, 2), inter_cache

    streaming.SFE.forward = sfe_forward
    streaming.StreamGTConvBlock.shuffle = shuffle
    streaming.StreamGTConvBlock.forward = block_forward
    streaming.GRNN.forward = grnn_forward
    streaming.DPGRNN.forward = dpgrnn_forward

    base = GTCRN().eval()
    base.load_state_dict(torch.load(checkpoint, map_location="cpu")["model"])
    stream_model = streaming.StreamGTCRN().eval()
    convert_to_stream(stream_model, base)

    class FunctionalStream(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, mix, conv_cache, tra_cache, inter_cache):
            # The official module updates cache slices in place. Cloning exposes
            # the same values as ordinary outputs, which Core ML can carry into
            # the next prediction without input mutation.
            return self.model(
                mix,
                conv_cache.clone(),
                tra_cache.clone(),
                inter_cache.clone(),
            )

    return FunctionalStream(stream_model).eval(), checkpoint, reference


def prove_onnx_parity(model, reference: Path):
    import onnxruntime as ort
    import torch

    session = ort.InferenceSession(str(reference), providers=["CPUExecutionProvider"])
    observed_inputs = [(item.name, tuple(item.shape)) for item in session.get_inputs()]
    observed_outputs = [item.name for item in session.get_outputs()]
    if observed_inputs != list(zip(INPUT_NAMES, INPUT_SHAPES)):
        raise ValueError(f"unexpected GTCRN inputs: {observed_inputs}")
    if observed_outputs != OUTPUT_NAMES:
        raise ValueError(f"unexpected GTCRN outputs: {observed_outputs}")

    rng = np.random.default_rng(0x47C2)
    ort_states = [np.zeros(shape, dtype=np.float32) for shape in INPUT_SHAPES[1:]]
    torch_states = [torch.zeros(shape) for shape in INPUT_SHAPES[1:]]
    maximum_error = 0.0
    for _ in range(4):
        spectrum = rng.normal(0, 1, INPUT_SHAPES[0]).astype(np.float32)
        expected = session.run(
            None,
            dict(zip(INPUT_NAMES, [spectrum, *ort_states])),
        )
        with torch.no_grad():
            actual = model(torch.from_numpy(spectrum), *torch_states)
        for reference_value, actual_value in zip(expected, actual):
            np.testing.assert_allclose(
                actual_value.detach().numpy(), reference_value, rtol=3e-5, atol=6e-6
            )
            maximum_error = max(
                maximum_error,
                float(np.max(np.abs(actual_value.detach().numpy() - reference_value))),
            )
        ort_states = expected[1:]
        torch_states = [value.detach() for value in actual[1:]]
    print(f"ONNX parity: passed (maximum error {maximum_error:.3g})")


def convert(model, out_dir: Path):
    import coremltools as ct
    import torch

    rng = np.random.default_rng(0xC0DE)
    example = (
        torch.from_numpy(rng.normal(0, 1, INPUT_SHAPES[0]).astype(np.float32)),
        *(torch.zeros(shape) for shape in INPUT_SHAPES[1:]),
    )
    traced = torch.jit.trace(model, example, strict=False)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name=name, shape=shape, dtype=np.float32)
            for name, shape in zip(INPUT_NAMES, INPUT_SHAPES)
        ],
        outputs=[
            ct.TensorType(name=name, dtype=np.float32)
            for name in OUTPUT_NAMES
        ],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.author = "Rong Xiaobin; Core ML conversion by Kurn"
    mlmodel.license = "MIT"
    mlmodel.version = "GTCRN official source commit 3862c448"
    mlmodel.short_description = "Streaming 16 kHz GTCRN speech enhancement"

    out_dir.mkdir(parents=True, exist_ok=True)
    package = out_dir / f"{MODEL_NAME}.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    mlmodel.save(str(package))
    return mlmodel, package, example


def prove_coreml_parity(torch_model, mlmodel, example):
    import torch

    with torch.no_grad():
        expected = torch_model(*example)
    actual = mlmodel.predict(
        dict(zip(INPUT_NAMES, [value.detach().numpy() for value in example]))
    )
    maximum_error = 0.0
    for name, reference_value in zip(OUTPUT_NAMES, expected):
        result = actual[name]
        reference_array = reference_value.detach().numpy()
        np.testing.assert_allclose(result, reference_array, rtol=3e-2, atol=2e-2)
        maximum_error = max(
            maximum_error, float(np.max(np.abs(result - reference_array)))
        )
    print(f"Core ML parity: passed (maximum error {maximum_error:.3g})")


def write_config(out_dir: Path):
    config = {
        "modelName": MODEL_NAME,
        "sampleRate": SAMPLE_RATE,
        "frameSize": FRAME_SIZE,
        "hopSize": HOP_SIZE,
        "binCount": BIN_COUNT,
        "spectrumInput": INPUT_NAMES[0],
        "spectrumOutput": OUTPUT_NAMES[0],
        "states": [
            {"input": input_name, "output": output_name, "shape": list(shape)}
            for input_name, output_name, shape in zip(
                INPUT_NAMES[1:], OUTPUT_NAMES[1:], INPUT_SHAPES[1:]
            )
        ],
    }
    path = out_dir / f"{CONFIG_NAME}.json"
    path.write_text(json.dumps(config, indent=2) + "\n")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="official GTCRN checkout")
    parser.add_argument("--out", type=Path, default=BUNDLE_DIR)
    parser.add_argument(
        "--skip-coreml-parity",
        action="store_true",
        help="only for restricted build environments that cannot compile Core ML models",
    )
    args = parser.parse_args()

    model, checkpoint, reference = import_official_model(args.source.resolve())
    print(f"Checkpoint: {checkpoint}")
    print(f"  sha256 {sha256(checkpoint)}")
    print(f"Reference ONNX: {reference}")
    print(f"  sha256 {sha256(reference)}")
    prove_onnx_parity(model, reference)
    mlmodel, package, example = convert(model, args.out.resolve())
    if not args.skip_coreml_parity:
        prove_coreml_parity(model, mlmodel, example)
    config = write_config(args.out.resolve())
    print(f"Wrote {package}")
    print(f"Wrote {config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
