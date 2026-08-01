# GTCRN → Core ML

Converts the official streaming GTCRN speech-enhancement model to the fp16 Core
ML package bundled by Kurn. GTCRN runs at 16 kHz with a 512-sample square-root
Hann window, a 256-sample hop, and three recurrent caches.

The bundled model uses the DNS3 checkpoint from the official repository at
commit `3862c44808dca492ea5a8a145d2dc2a1028d08c8`:

- Project: <https://github.com/Xiaobin-Rong/gtcrn>
- License: MIT, including source and checkpoints
- Checkpoint SHA-256:
  `250fa2820ea9947704a62dda8e642ba773a067719c5e4294ad95aeab23f06442`
- Reference `gtcrn_simple.onnx` SHA-256:
  `b4718df6228e7bdf1a8a435cf98f838636eb2fd331acabf86ba87c5192ebcb87`

The converter validates four consecutive streaming frames against ONNX Runtime,
converts the fixed-shape graph, then validates Core ML against PyTorch. It writes
`GTCRN.mlpackage` and `gtcrn.json` into `Kurn/Resources/Models/`.

```bash
git clone https://github.com/Xiaobin-Rong/gtcrn.git /tmp/gtcrn
git -C /tmp/gtcrn checkout 3862c44808dca492ea5a8a145d2dc2a1028d08c8

cd Tools/gtcrn
python3 -m venv .venv
source .venv/bin/activate
pip install "coremltools==9.0" "torch==2.7.0" onnxruntime numpy einops
python convert.py --source /tmp/gtcrn
```

The model is an ML Program with an iOS 16 deployment floor. `SpeechEnhancer`
uses `.all`, allowing Core ML to partition supported operations across the CPU,
GPU, and Neural Engine. The model is intentionally kept streaming so memory is
bounded for long meetings.
