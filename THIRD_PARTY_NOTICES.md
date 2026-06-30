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

## Machine-learning models

Kurn downloads these CoreML models on demand (with the user's consent) through
FluidAudio. They are not bundled in the app binary; each is fetched from its
upstream distribution and cached on device.

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

---

This list is maintained on a best-effort basis. For the authoritative license
text of each component, see its upstream project linked above. Model license
terms — in particular the NVIDIA Open Model License covering Sortformer — should
be reviewed directly before redistribution.
