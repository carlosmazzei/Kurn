# Third-Party Notices

Kurn includes and/or downloads third-party software and machine-learning models.
Their copyrights remain with their respective owners, and they are used under the
licenses listed below. This file is provided to satisfy the attribution
requirements of those licenses.

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

### Automatic speech recognition — Parakeet TDT (v2 / v3)

- Origin: NVIDIA NeMo Parakeet TDT
- Used for: on-device and live multilingual transcription
- License: permissive open-source model license; attribution to NVIDIA.

### Speaker diarization — pyannote, WeSpeaker, NVIDIA Sortformer

- pyannote-audio: https://github.com/pyannote/pyannote-audio (MIT)
- WeSpeaker: https://github.com/wenet-e2e/wespeaker (Apache License 2.0)
- NVIDIA Sortformer: distributed under the **NVIDIA Open Model License**.

### Voice activity detection — Silero VAD

- Project: https://github.com/snakers4/silero-vad
- License: MIT License

### Automatic speech recognition — OpenAI Whisper (GGML)

- Origin: OpenAI Whisper, converted to GGML format by the whisper.cpp project
- Distribution: https://huggingface.co/ggerganov/whisper.cpp
- Used for: on-device Whisper transcription (`base`, `small`, `large-v3-turbo`,
  q5-quantized; downloaded only when the user selects the engine)
- License: MIT License (OpenAI Whisper model weights)

### Speech enhancement — DPDFNet

- Project: https://github.com/ceva-ip/DPDFNet
- Paper: "DPDFNet: Boosting DeepFilterNet2 via Dual-Path RNN" (arXiv:2512.16420)
- Used for: optional noise removal in the enhanced playback copy (`dpdfnet8`,
  16 kHz variant, converted to Core ML by `Tools/dpdfnet/convert.py` and bundled
  with the app)
- License: Apache License 2.0, covering both source and pretrained weights
- Note: not bundled until the conversion in `Tools/dpdfnet/` has been run. Record
  the release tag and the ONNX SHA-256 here when the model is committed.

---

This list is maintained on a best-effort basis. For the authoritative license
text of each component, see its upstream project linked above. Model license
terms — in particular the NVIDIA Open Model License covering Sortformer — should
be reviewed directly before redistribution.
