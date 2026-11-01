# Third-Party Notices

Kurn includes and/or downloads third-party software and machine-learning models.
Their copyrights remain with their respective owners, and they are used under the
licenses listed below. This file records attribution and upstream license
sources; it does not replace full license copies or other notices required
when distributing third-party materials.

## Swift packages

### FluidAudio

- Project: https://github.com/FluidInference/FluidAudio
- Author: FluidInference Team
- License: Apache License 2.0

> Copyright FluidInference contributors.
>
> Licensed under the Apache License, Version 2.0 (the "License"); you may not use
> this software except in compliance with the License. You may obtain a copy of
> the License at http://www.apache.org/licenses/LICENSE-2.0.
>
> Unless required by applicable law or agreed to in writing, software distributed
> under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
> CONDITIONS OF ANY KIND, either express or implied. See the License for the
> specific language governing permissions and limitations under the License.

Citation, as requested by the project:

> FluidInference Team. (2025). *FluidAudio: Local Speaker Diarization, ASR, and
> VAD for Apple Platforms.* https://github.com/FluidInference/FluidAudio

Speech features in Kurn are **Powered by Fluid Inference**.

### sherpa-onnx

- Project: https://github.com/k2-fsa/sherpa-onnx
- Author: The Next-gen Kaldi (k2-fsa) contributors
- License: Apache License 2.0

Optional third diarization engine (segmentation-first, CPU-only via ONNX
Runtime), added alongside FluidAudio's neural engine for far-field/single-mic
recordings where FluidAudio's clustering step collapses to one speaker (whether
it does is still being measured — see `docs/roadmap.md`, D4). Linked as a remote Swift package (mirroring
FluidAudio's integration, not whisper.cpp's local binary wrapper), which
resolves its own transitive `onnxruntime-libs` dependency.

> Copyright the Next-gen Kaldi contributors.
>
> Licensed under the Apache License, Version 2.0 (the "License"); you may not use
> this software except in compliance with the License. You may obtain a copy of
> the License at http://www.apache.org/licenses/LICENSE-2.0.
>
> Unless required by applicable law or agreed to in writing, software distributed
> under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
> CONDITIONS OF ANY KIND, either express or implied. See the License for the
> specific language governing permissions and limitations under the License.

### whisper.cpp

- Project: https://github.com/ggml-org/whisper.cpp
- Author: Georgi Gerganov and the ggml.ai contributors
- License: MIT License

Linked as the project's official prebuilt XCFramework, and used for the
on-device Whisper transcription engine.

> Copyright (c) 2023-2024 The ggml authors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in
> the Software without restriction, including without limitation the rights to
> use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
> of the Software, and to permit persons to whom the Software is furnished to do
> so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## Machine-learning models

Kurn downloads these models on demand (with the user's consent) — the CoreML ones
through FluidAudio, the GGML Whisper weights directly. They are not bundled in
the app binary; each is fetched from its upstream distribution and cached on
device.

FluidAudio's Apache License 2.0 covers the framework, not all model weights
loaded through it. The additional ASR and Nemotron 3 diarization models below
are optional alternatives; Parakeet and the existing Pyannote-based diarization
remain the defaults. Core ML conversions retain the model licenses identified
by their respective upstream cards and notices.

### Automatic speech recognition — Parakeet TDT (v2 / v3)

- Origin: NVIDIA NeMo Parakeet TDT
- Used for: on-device and live multilingual transcription
- License: permissive open-source model license; attribution to NVIDIA.

### Automatic speech recognition — NVIDIA Nemotron Labs Unified ASR 0.6B

- Origin: NVIDIA, https://huggingface.co/nvidia/nemotron-labs-unified-asr-0.6b
- Core ML conversion: Fluid Inference,
  https://huggingface.co/FluidInference/nemotron-labs-unified-asr-0.6b-coreml
  (`coreml/` subdirectory; offline and streaming variants of one checkpoint)
- Used for: optional batch and live transcription in 25 European languages
- Model license: **OpenMDW License Agreement, version 1.1 (OpenMDW-1.1)**
- License and copyright notice:
  https://huggingface.co/FluidInference/nemotron-labs-unified-asr-0.6b-coreml/raw/main/LICENSE.md
- Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
- Changes by Fluid Inference: Core ML conversion, including int8-quantized
  encoders. The conversion is unofficial and is not endorsed by NVIDIA or Apple.

### Automatic speech recognition — Nemotron 3.5 Transcribe Lite

- Origin: NVIDIA Nemotron 3.5 Transcribe,
  https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B
- Core ML conversion: Fluid Inference,
  https://huggingface.co/FluidInference/nemotron-3.5-transcribe-lite-coreml
- Used for: optional English ASR using the audio encoder and CTC timestamp head
  only, without the upstream language model. “Lite” is Fluid Inference's name
  for this unofficial port, not an NVIDIA model or release. The separate
  Nemotron 3 diarizer is credited below.
- Model license: **OpenMDW License Agreement, version 1.1 (OpenMDW-1.1)**
- License and copyright notice:
  https://huggingface.co/FluidInference/nemotron-3.5-transcribe-lite-coreml/raw/main/LICENSE
- Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
- Changes by Fluid Inference: extraction of the ASR components and conversion
  to Core ML. The port is not endorsed by NVIDIA or Apple.

### Automatic speech recognition — Underdog Bark 3.0 / Bark 3.0 Clean

- Authors: Conway Research (Underdog)
- Origins: https://huggingface.co/ConwayResearch/Underdog-Bark-3.0 and
  https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Clean
- Core ML conversion: Fluid Inference,
  https://huggingface.co/FluidInference/bark-3.0-coreml (`bark-3.0/` and
  `bark-3.0-clean/` subdirectories)
- Used for: optional English ASR; Bark 3.0 preserves disfluencies, while Clean
  is trained to remove fillers, false starts and repeated words
- Model license: **Creative Commons Attribution 4.0 International (CC-BY-4.0)**,
  https://creativecommons.org/licenses/by/4.0/
- License text:
  https://huggingface.co/FluidInference/bark-3.0-coreml/raw/main/LICENSE
- Upstream attribution notices:
  https://huggingface.co/FluidInference/bark-3.0-coreml/raw/main/bark-3.0/NOTICE and
  https://huggingface.co/FluidInference/bark-3.0-coreml/raw/main/bark-3.0-clean/NOTICE
- Derived from NVIDIA Parakeet TDT 0.6B v3 (© NVIDIA Corporation),
  https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3, through Parakeet Ultra
  (© Moondream), https://huggingface.co/moondream/parakeet-ultra; both CC-BY-4.0.
- Changes: post-trained and compressed by Conway Research; Clean builds on
  Bark 3.0 Plus with disfluency removal. Converted and re-encoded to Core ML
  by Fluid Inference, preserving the encoder's quantized weight values and
  converting the remaining upstream tensors to fp16.

### Automatic speech recognition — Phonon-2

- Author: Fermion Research, https://huggingface.co/FermionResearch/Phonon-2
- Core ML conversion: Fluid Inference,
  https://huggingface.co/FluidInference/phonon-2-coreml
- Used for: optional English ASR
- Model license: **Creative Commons Attribution 4.0 International (CC-BY-4.0)**,
  https://creativecommons.org/licenses/by/4.0/
- License text: https://huggingface.co/FluidInference/phonon-2-coreml/raw/main/LICENSE
- Upstream notice: https://huggingface.co/FluidInference/phonon-2-coreml/raw/main/NOTICE
- Phonon-2 — Copyright 2026 Fermion Research. This product includes software
  and models developed by Fermion Research.
- Derived from NVIDIA Parakeet TDT 0.6B v3 (© NVIDIA Corporation),
  https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3, under CC-BY-4.0.
- Changes: encoder linear weights re-trained and quantized to five values per
  row by Fermion Research; remaining parameters quantized to 6-bit integer
  tables. Fluid Inference re-encoded the encoder values as Core ML palettes
  and exported decoder/joint tables to fp16, using the Parakeet v3 preprocessor
  and vocabulary.
- Training-data attribution retained from the upstream notice: CHiME-6
  (CC-BY-SA-4.0), https://chimechallenge.github.io/chime6/ and
  https://creativecommons.org/licenses/by-sa/4.0/; SPGISpeech under Kensho's
  public terms, https://datasets.kensho.com/datasets/spgispeech.
  These are upstream training-data notices, not a relicensing of the weights.
- Fermion's repository code is Apache License 2.0; that does not replace the
  CC-BY-4.0 license on the model weights.

### Speaker diarization — pyannote, WeSpeaker, NVIDIA Sortformer

- pyannote-audio: https://github.com/pyannote/pyannote-audio (MIT)
- WeSpeaker: https://github.com/wenet-e2e/wespeaker (Apache License 2.0)
- NVIDIA Sortformer: distributed under the **NVIDIA Open Model License**.

### Speaker diarization — NVIDIA Nemotron 3 Diarization (8 speakers)

- Origin: NVIDIA, https://huggingface.co/nvidia/Nemotron-3-Diarization
- Core ML conversion: Fluid Inference,
  https://huggingface.co/FluidInference/nemotron-3-diarization-coreml
- Used for: optional on-device speaker diarization for up to eight speakers;
  distinct from the existing NVIDIA Sortformer model credited above
- Model license: **OpenMDW License Agreement, version 1.1 (OpenMDW-1.1)**,
  https://openmdw.ai/license/1-1/ (linked by NVIDIA's model card)
- The Core ML model card explicitly states that the converted weights carry
  the same license as NVIDIA's model. Core ML conversion, runtime and
  benchmarks are by Fluid Inference.

### Speaker diarization (sherpa-onnx engine) — pyannote segmentation, 3D-Speaker CAM++

Downloaded directly by `SherpaOnnxModelDownloader` (not through FluidAudio)
when the user opts into the sherpa-onnx diarization engine — same on-demand,
consent-gated shape as the whisper.cpp weights below.

- Segmentation: converted from `pyannote/segmentation-3.0`
  (https://huggingface.co/pyannote/segmentation-3.0), **MIT License** — the
  model checkpoint itself, not only the pyannote-audio training code above.
  Redistributed as an ONNX conversion by k2-fsa's maintainer
  (https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0),
  which inherits the same MIT terms; the app downloads a pinned commit of
  that file (see `SherpaOnnxModelDownloader.swift`), byte-identical to
  `model.onnx` in k2-fsa's official GitHub release archive.
- Speaker embedding: CAM++ from the 3D-Speaker project
  (https://github.com/modelscope/3D-Speaker), **Apache License 2.0**.
  Redistributed as an ONNX conversion by k2-fsa.

### Voice activity detection — Silero VAD

- Project: https://github.com/snakers4/silero-vad
- License: MIT License

### Automatic speech recognition — OpenAI Whisper (GGML)

- Origin: OpenAI Whisper, converted to GGML format by the whisper.cpp project
- Distribution: https://huggingface.co/ggerganov/whisper.cpp
- Used for: on-device Whisper transcription (`base`, `small`, `large-v3-turbo`,
  q5-quantized; downloaded only when the user selects the engine)
- License: MIT License (OpenAI Whisper model weights)

### Speech enhancement — GTCRN

- Project: https://github.com/Xiaobin-Rong/gtcrn
- Paper: "GTCRN: A Speech Enhancement Model Requiring Ultralow Computational
  Resources" (ICASSP 2024)
- Used for: streaming 16 kHz noise removal in the enhanced playback copy,
  converted to Core ML by `Tools/gtcrn/convert.py` and bundled with the app
- License: MIT, covering the source and checkpoints in the official repository
- Source revision: `3862c44808dca492ea5a8a145d2dc2a1028d08c8`
- DNS3 checkpoint SHA-256:
  `250fa2820ea9947704a62dda8e642ba773a067719c5e4294ad95aeab23f06442`
- Reference streaming ONNX SHA-256:
  `b4718df6228e7bdf1a8a435cf98f838636eb2fd331acabf86ba87c5192ebcb87`

## License and notice retention for the additional models

The public Hugging Face cards for Unified ASR, Transcribe Lite, Bark 3.0/Clean,
Phonon-2 and Nemotron 3 Diarization identify the weight licenses above; the
Hugging Face API reports each of these Core ML repositories as `gated: false`.
Public access does not waive license conditions.

**OpenMDW-1.1:** the full agreement in the Unified ASR and Transcribe Lite
license files requires that any distribution of any portion of the Model
Materials retain (1) a copy of the agreement and (2) all applicable copyright
and other notices of origin included in those materials. A model-card or
acknowledgement link alone is not that copy. The full verified agreement and
applicable origin notices are retained in
`Kurn/Resources/FluidAudioModelLicenses.txt`, together with the full CC-BY-4.0
license, both Bark variant notices and the full Phonon-2 notice. Source URLs
and verbatim-block boundaries identify the copied upstream text. Settings →
Acknowledgements provides an offline, selectable-text view of this resource
using the main app bundle. Before release, verify that the built app includes
the resource and that the offline view opens; `FluidAudioModelLicensesTests`
checks the app-bundle resource and the complete OpenMDW agreement. Retain
these texts with any separately redistributed model materials as well.

**CC-BY-4.0:** retain creator/copyright attribution, upstream modification
notices and a link to the license, including its disclaimer of warranties
(Section 5), https://creativecommons.org/licenses/by/4.0/. Section 3 allows
a license link instead of a full license copy. Preserve the Bark and Phonon-2
`NOTICE` information linked above when sharing the model materials. The
upstream Python/MLX reference-runtime dependency lists do not imply those
runtimes are bundled in Kurn's Core ML integration.

---

This list is maintained on a best-effort basis. For the authoritative license
text of each component, see its upstream project linked above. Model license
terms — in particular the NVIDIA Open Model License covering Sortformer — should
be reviewed directly before redistribution.
