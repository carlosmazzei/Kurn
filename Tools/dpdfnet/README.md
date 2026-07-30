# DPDFNet → Core ML

Converts the DPDFNet speech-enhancement model to Core ML for the enhanced
playback copy (`Kurn/Services/Enhancement/`).

This is a **manual, occasional step**, not part of the build. It needs macOS,
Python and `coremltools`, none of which CI has. Until it has been run, the app
builds and works: `SpeechEnhancer` reports that no model is installed and
`PlaybackEnhancementRenderer` runs its DSP chain alone. That is a supported
configuration, not a degraded one — denoising removes the noise *around* a quiet
talker without making the talker louder, which is the compressor's and the
loudness normalization's job.

## Which model

**`dpdfnet8`, 16 kHz.** 3.54M parameters, 4.37 GMAC/s, ~7 MB once converted to
fp16.

- 16 kHz because that is the rate the model was trained at, and resampling the
  app's 24 kHz recordings to it is cheap. The wet signal is band-limited to
  8 kHz as a result, which is why the plan is to mix ~15% of the original back
  in: it returns the 8–12 kHz band about 16 dB down, and masks the artefacts a
  denoiser leaves behind. That mix stage does not exist yet — it lands with the
  inference loop, since neither can be heard without the other.
- `dpdfnet8` rather than a smaller variant because generation is offline and
  one-time per recording, so the extra compute costs a few seconds once rather
  than anything sustained.

Source: <https://github.com/ceva-ip/DPDFNet> — Apache-2.0, covering both code and
pretrained weights. Record the exact release tag and the ONNX file's SHA-256
(the script prints it) in `THIRD_PARTY_NOTICES.md` when you commit the model.

## Running it

```bash
cd Tools/dpdfnet
python3 -m venv .venv && source .venv/bin/activate
pip install coremltools onnx numpy onnxruntime onnx2pytorch "torch==2.7.0"

# 1. Look at the graph first. Nothing is written.
python3 convert.py --onnx ~/Downloads/dpdfnet8_16khz.onnx --inspect-only

# 2. Convert. Writes into Kurn/Resources/Models/.
python3 convert.py --onnx ~/Downloads/dpdfnet8_16khz.onnx
```

The release currently names this file `onnx/dpdfnet8.onnx` in the
[official model repository](https://huggingface.co/Ceva-IP/DPDFNet); the local
`_16khz` suffix above makes it harder to confuse with the separate 48 kHz
variant. The converter bridges ONNX through PyTorch because current
`coremltools` no longer has an ONNX frontend, and checks that bridge against
ONNX Runtime before writing anything. Keep PyTorch at the maximum version the
installed `coremltools` declares compatible (2.7.0 for coremltools 9).

The script prints the ONNX graph's real inputs and outputs before touching
anything, and guesses which tensor is the spectrum and which is the recurrent
state from their shapes. If it guesses wrong, the printed interface is the
ground truth — override it:

```bash
python3 convert.py --onnx … \
  --spectrum-input spec --state-input state \
  --spectrum-output spec_e --state-output state_out
```

## What it produces

Two files in `Kurn/Resources/Models/`:

| File | Purpose |
| --- | --- |
| `DPDFNet.mlpackage` | the converted model, fp16, ML Program, iOS 16 floor |
| `dpdfnet.json` | tensor names and shapes **as discovered**, read by `SpeechEnhancerModelConfig` |

The JSON is the reason this script exists in the form it does. Hardcoding tensor
names and bin counts in Swift from reading the model's documentation produces
something that loads, runs, and returns plausible-sounding garbage that nothing
downstream detects. Discovering them at conversion time and writing them down
makes a mismatch a startup error instead.

After converting, add both files to the `Kurn` target's **Copy Bundle
Resources** phase in Xcode. The project uses file-system-synchronized groups, so
source files are picked up automatically — resources are not.

## Notes

- The recurrent state stays an ordinary input/output pair rather than an iOS 18
  `StateType`. More portable, and much simpler to drive frame by frame.
- DPDFNet is a dual-path RNN, and Core ML does not place recurrent layers on the
  Neural Engine — expect GPU or CPU. That is fine here (everything runs offline),
  but do not describe the feature as ANE-accelerated.
- Bumping the model is a code change too: bump
  `PlaybackEnhancementRenderer.currentVersion` so already-rendered copies are
  regenerated rather than served stale.
