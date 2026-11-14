# Pipeline evaluation results

Measured word error rate (WER) and diarization error rate (DER) for Kurn's
recognition pipeline, recorded here run by run.

Each entry comes from a dispatch of
[`.github/workflows/pipeline-eval.yml`](../.github/workflows/pipeline-eval.yml),
which runs the app's **actual** pipeline — `TranscriptionService`, exactly as
`TranscriptionViewModel` drives it, not a stand-in — over public benchmark
audio, once per configuration in `PipelineEvaluationMatrix`
(preprocessing × VAD × diarization × ASR engine). See
[`Tools/evaluation/public_datasets/README.md`](../Tools/evaluation/public_datasets/README.md)
for the corpora and how to produce a run, and
[`Tools/evaluation/README.md`](../Tools/evaluation/README.md) for measuring
against your own recordings instead.

This file exists because the workflow's own output does not survive: the job
summary is attached to a run page and the `pipeline-eval-report` artifact is
deleted after 90 days. A number in git is diffable — when a change to a
pipeline stage moves WER or DER, that shows up in a pull request.

## How to read these numbers

- **There is deliberately no pass/fail threshold.** A budget invented in this
  repository would have no provenance, and the first time it failed the
  temptation would be to raise it. Record the number, change something, run it
  again.
- **They are comparable between runs over the same material, not against
  published figures for the same audio.** The normalization
  (`KurnTests/Support/Evaluation/TextNormalizer.swift`) is deliberately
  language-neutral — no number expansion, no contraction splitting, no
  filler-word list — and for Chinese and Japanese the rate is a *character*
  error rate, because those are written without spaces. A LibriSpeech WER here
  and a LibriSpeech WER in a paper are not the same measurement.
- **Since 2026-09-26 a second set of numbers comes from the reference tools.**
  `Tools/evaluation/rescore.py` re-scores the same pipeline output with
  Whisper's normalizers + `jiwer` ("WER standard" — the Open ASR Leaderboard
  convention, the only WER here loosely comparable to a paper), `meeteval`
  (cpWER, speaker-attributed WER on AMI) and `pyannote.metrics` (DER at
  ±0.25 s and with no collar). It also cross-checks the harness: on 1071 real
  cells its DER matched `pyannote.metrics` to 0.0000pp.
- **DER here uses a ±0.25 s collar (NIST RT / VoxConverse).** pyannote's and
  DIHARD's published AMI figures use none, which reads ~7pp higher on the same
  output; state the collar with any DER quoted.
- **Every rate is micro-averaged over the corpus**: total errors divided by
  total reference, not the mean of the per-file rates. A short file with one
  bad word cannot dominate — but the corpus with the most speech does. That is
  deliberate: AMI's meetings are weighted to dominate English, because the app
  records meetings. It also means a language total mixes read speech with
  meeting speech, which is why runs are reported **per corpus** as well;
  read that grain when deciding anything.
- **A missing row is a skip, not a 0%.** The harness skips a (language, engine)
  pair the engine cannot serve — Apple Speech is fixed to the device locale, so
  it is absent from every Portuguese table below. Skips are listed under each
  run.
- **DER for Portuguese is a known gap.** No public, freely downloadable
  multi-speaker Portuguese corpus with turn-level annotation comparable to AMI
  was identified, so Portuguese runs score WER only.

## Recording a run

1. Dispatch **Pipeline evaluation (public datasets)** from the Actions tab.
   `matrix: full` sweeps everything; `essential` is the fast subset. Narrow
   `corpora` to save runner time.
2. When it finishes, the job summary already shows the rendered table, and the
   `pipeline-eval-report` artifact carries `report.csv`, `pipeline-eval.log`
   and a ready-made `pipeline-evaluation.md`.
3. Paste that Markdown into the [Runs](#runs) section below, newest first, and
   commit it. Or regenerate it yourself from the artifact:

   ```bash
   python3 Tools/evaluation/report_to_markdown.py \
     --csv report.csv --log pipeline-eval.log \
     --commit "$(git rev-parse HEAD)" \
     --run-url https://github.com/carlosmazzei/Kurn/actions/runs/<id>
   ```

Record a run when the numbers moved, or when the matrix changed shape. Not
every dispatch is worth a commit.

## Runs at a glance

Every dispatch recorded below, newest first. "Scope" is what the dispatch
actually swept — narrower scopes exist because a full matrix costs real CI
minutes (and real LLM API spend for cloud/correction entries), so most runs
after the first deliberately target one question rather than re-measuring
everything.

| Date | Commit | Scope | Corpora | Workflow run(s) |
| --- | --- | --- | --- | --- |
| 2026-11-06 | `b8d6db1` | sherpa-onnx 2.0.1 regression check: `sherpaOnnx` × `fluidAudioParakeet`, `matrix: full` (4 configs, prep × VAD) | AMI (4, WER+DER) | [42229034531](https://github.com/carlosmazzei/Kurn/actions/runs/42229034531) |
| 2026-11-05 | `3a81c91` / `21c414a` | LLM correction before and after the topic-critique rewrite (#312): the same Nemotron Unified matrix (prep × VAD, Pyannote, 4 configs) with `correction: on` (baseline + corrected twin, OpenAI) on the old corrector (`main`) and the new one (branch) | AMI (4, WER+DER), LibriSpeech (6), CAMOES (40), CORAA (40) | [old corrector](https://github.com/carlosmazzei/Kurn/actions/runs/42097203848), [new corrector](https://github.com/carlosmazzei/Kurn/actions/runs/42097769947) |
| 2026-11-03 | `5cfc919` | Six dispatches to fill the gaps the 2026-11-01 runs left: Parakeet v3 + whisper.cpp `largeTurbo` (8 configs); Parakeet v3 in Portuguese (4); Nemotron 3 diarization × Parakeet v3 / Phonon-2 (8); ElevenLabs `scribe_v1` + `scribe_v2` × `fluidAudio` / native diarization (16); whisper.cpp `small` (4); Groq `whisper-large-v3` + turbo (8). All four AMI meetings fetched in every English run | AMI (4, WER+DER), LibriSpeech (6), CAMOES (40), CORAA (40) | [Parakeet + largeTurbo](https://github.com/carlosmazzei/Kurn/actions/runs/41693244971), [Parakeet pt](https://github.com/carlosmazzei/Kurn/actions/runs/41693250571), [Nemotron 3 AMI](https://github.com/carlosmazzei/Kurn/actions/runs/41694750856), [ElevenLabs](https://github.com/carlosmazzei/Kurn/actions/runs/41699659363), [whisper.cpp small](https://github.com/carlosmazzei/Kurn/actions/runs/41699664893), [Groq](https://github.com/carlosmazzei/Kurn/actions/runs/41702642987) |
| 2026-11-01 | `aebf04e` | Nemotron 3 against Pyannote diarization, Parakeet ASR, 8 configs (prep × VAD × diarization model) | VoxConverse (4, DER) | [41339676563](https://github.com/carlosmazzei/Kurn/actions/runs/41339676563) |
| 2026-11-01 | `f6745bb` | Five dispatches on the new FluidAudio model axes: Nemotron Unified, Bark 3.0/Clean, Phonon-2 and Transcribe Lite in English (20 configs) and Nemotron Unified in Portuguese (4); whisper.cpp `base` + `largeTurbo` in English and Portuguese (8 each); Groq `whisper-large-v3-turbo` (4). AMI's mirror throttled the runners, so AMI coverage differs per dispatch | AMI (4 with WER for the FluidAudio models; 3 DER-only for whisper.cpp; 1 for Groq), LibriSpeech (6), CAMOES (40), CORAA (40) | [FluidAudio en](https://github.com/carlosmazzei/Kurn/actions/runs/41336072736), [Unified pt](https://github.com/carlosmazzei/Kurn/actions/runs/41336076180), [whisper.cpp en](https://github.com/carlosmazzei/Kurn/actions/runs/41336081989), [whisper.cpp pt](https://github.com/carlosmazzei/Kurn/actions/runs/41336084871), [Groq turbo](https://github.com/carlosmazzei/Kurn/actions/runs/41336088010) |
| 2026-11-01 | `924702e` | whisper.cpp `base` × `heuristic` / `fluidAudio` / `sherpaOnnx`, 12 configs | AMI (3 DER, 2 WER), LibriSpeech (6), CAMOES (40), CORAA (40) | [41315829712](https://github.com/carlosmazzei/Kurn/actions/runs/41315829712) |
| 2026-11-01 | `924702e` | ElevenLabs `scribe_v2` only, 8 configs (prep × VAD × `fluidAudio`/native diarization). AMI was DER-only on 3 meetings: the AMI server returned 403 for the annotation zip and one audio file | AMI (3, DER only), LibriSpeech (6), CAMOES (40), CORAA (40) | [41305791412](https://github.com/carlosmazzei/Kurn/actions/runs/41305791412) |
| 2026-09-26 | `986697b`…`5ae7fed` | Nine dispatches: AMI and VoxConverse × all three diarizers (Parakeet); full on-device baseline; OpenAI `whisper-1` / `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` (before and after the untimed-span fix, plus a Portuguese confirmation); Groq + LLM correction; ElevenLabs Scribe with `fluidAudio` and its own diarization (before and after the compaction fix) | AMI (4), VoxConverse (4, first run), LibriSpeech (6), CAMOES (40), CORAA (40) | [AMI diar](https://github.com/carlosmazzei/Kurn/actions/runs/36258369898), [VoxConverse](https://github.com/carlosmazzei/Kurn/actions/runs/36258371882), [baseline](https://github.com/carlosmazzei/Kurn/actions/runs/36258373738), [OpenAI](https://github.com/carlosmazzei/Kurn/actions/runs/36258538786), [OpenAI after fix](https://github.com/carlosmazzei/Kurn/actions/runs/36263668012), [OpenAI pt](https://github.com/carlosmazzei/Kurn/actions/runs/36268996027), [Groq+corr](https://github.com/carlosmazzei/Kurn/actions/runs/36258540773), [ElevenLabs](https://github.com/carlosmazzei/Kurn/actions/runs/36270575700), [ElevenLabs after fix](https://github.com/carlosmazzei/Kurn/actions/runs/36272374417) |
| 2026-08-27 | `6f0a094` | `sherpaOnnx` diarizer only × `whisperCpp@small`, 4 configs (prep × VAD) — first runtime measurement of D4, not yet compared against `fluidAudio` | AMI (4), LibriSpeech (6), CAMOES (40), CORAA (40) | [33029297796](https://github.com/carlosmazzei/Kurn/actions/runs/33029297796) |
| 2026-08-09 | `53db49c` | LLM transcript correction (D-stage), `essential`×`whisperCpp/small` paired on/off (16 rows) + `full`×`fluidAudioParakeet` corrected-only (8 rows) vs. the 2026-08-03 baseline | AMI (4), LibriSpeech (6), CAMOES (40), CORAA (40) | [essential+correction](https://github.com/carlosmazzei/Kurn/actions/runs/31284831125), [Parakeet+correction](https://github.com/carlosmazzei/Kurn/actions/runs/31307328299) |
| 2026-08-03 | `2644589` | `full` matrix — 32 English configs (on-device × `whisperAPI:groq`) + 16 Portuguese configs (diarizer axis collapsed, no PT reference RTTM) | AMI (4, WER+DER), LibriSpeech (6, WER), CAMOES (40, WER), CORAA (40, WER) | [30800039020](https://github.com/carlosmazzei/Kurn/actions/runs/30800039020) |
| 2026-08-02 | `3eecdcc` | Portuguese only, 16 configs — predates the corpus rebalance and the per-corpus aggregate | CAMOES (12), CORAA (12) | [30752932441](https://github.com/carlosmazzei/Kurn/actions/runs/30752932441) |

Dispatches with no entry, and why (audited 2026-11-03 against every run of the
workflow): the 2026-08-01/02 runs before `3eecdcc` were the harness being
built, and their logs and artifacts have expired; `36258542329` selected zero
configurations; `33025851651` failed on a sherpa-onnx model download (HTTP
404) before scoring; `41316277469` (whisper.cpp `largeTurbo`) was cancelled
after 324 rows and superseded by `41336081989`/`41336084871`; `41336079434`
failed in the AMI fetch; every other cancelled run scored nothing.

Open questions no run has answered yet:

- **Apple Speech** — the app's default engine — **cannot be measured in CI.**
  The 2026-09-26 baseline confirmed why every cell is skipped: in the
  simulator `SpeechTranscriber` reports English and Portuguese as unsupported
  (`isAvailable` / `supportedLocale(equivalentTo:)`), so this is not a
  missing-asset problem a download would fix. It needs a device run.
- **DER for Portuguese**: no public, freely downloadable multi-speaker
  Portuguese corpus with turn-level annotation comparable to AMI has been
  identified, so every Portuguese row is WER-only.
- **Whether Nemotron 3 should become the default diarizer.** On AMI it
  misses twice Pyannote's speech (raw DER 28.26% against 18.08%) but confuses
  less than half as much, and cpWER is ~8pp better (2026-11-03). Which metric
  should decide, and what the missing voiceprints cost, is a product decision
  the numbers alone do not make (roadmap, D4).
- **Speed and memory on a phone.** Every run here is a macOS CI simulator;
  none says how the new models behave on an iPhone's ANE or within its
  memory limit (CLAUDE.md, "FluidAudio on-device models").
- **Live preview models are outside the harness.** The preview never goes
  through `TranscriptionService`, so neither automatic nor Unified streaming
  has a number.
- **Native diarization vs. the local one, per file.** ElevenLabs' own speaker
  turns give the best cpWER measured but a worse raw DER than `fluidAudio`
  (see Cross-run findings), and swing with the VAD choice. Four meetings
  cannot say whether that is the provider or the material.

Answered on 2026-11-03: Nemotron 3 on AMI; the new FluidAudio ASR models
against Parakeet v3 on the same code (Phonon-2 ~2.5pp ahead on fused DER at
equal WER, Parakeet v3 Portuguese reproduced exactly, so Nemotron Unified's
lead holds); `scribe_v2` WER on meetings; Groq and whisper.cpp `largeTurbo`
on all four AMI meetings.

Answered on 2026-11-01: the first measurements of every FluidAudio model added
in `2ccd8b6`, whisper.cpp `base` and `largeTurbo`, Groq `whisper-large-v3-turbo`
and ElevenLabs `scribe_v2`; and D4 read per file (below, "D4 per file").

Answered on 2026-09-26: D4 (sherpa-onnx is behind FluidAudio on raw DER on
both AMI and VoxConverse, same run), Groq + correction (ran clean, no 429),
and the first cloud comparisons beyond Groq — OpenAI's three models and
ElevenLabs Scribe.

## Cross-run findings

Conclusions that come from comparing runs rather than from any single
dispatch. They are recorded here, apart from the run entries, because no
`report.csv` contains them — each was derived by reading two runs against
each other.

Cross-run comparison is normally unsafe (different commits, different
pipeline code). Where it is done below, the reason it holds is stated
explicitly; where it does not hold, the number is left out rather than
qualified.

### Best measured configuration, by use case

| Use case | Configuration | WER | DER (fused) | Source |
| --- | --- | --- | --- | --- |
| Meetings (AMI, en), on-device | `standardDSP` + `energyThreshold` + `fluidAudio` + `fluidAudioParakeet` | 22.27% | 24.66% | 2026-11-03 (33.26% fused DER on 2026-09-26, before the fusion fix) |
| Meetings (AMI, en), on-device, who said what | `standardDSP` + `energyThreshold` + `fluidAudio@nemotron3` + `fluidAudioParakeet@phonon2` | 22.43% | 20.44% (cpWER **25.05%**) | 2026-11-03 (Parakeet v3 + Nemotron 3: cpWER 24.49–27.22%; with Pyannote 33.28–33.96%) |
| Meetings (AMI, en), cloud | `standardDSP` + `energyThreshold` + `fluidAudio` + `whisperAPI:elevenLabs` | 15.86% (14.44% standard) | 19.73% | 2026-11-03 (`scribe_v2` ties: 16.01%) |
| Meetings (AMI, en), cloud, who said what | `none` + `fluidAudio` VAD + `transcriptionProviderNative` + `whisperAPI:elevenLabs@scribe_v2` | 16.01% | 18.54% (cpWER **17.06%**) | 2026-11-03 (`scribe_v1`: cpWER 17.66%; 18.19–18.47% on 2026-09-26) |
| Portuguese, aggregate | `none` + `energyThreshold` + `fluidAudioParakeet@nemotronUnified` | 23.87% | not measured | 2026-11-01 (Parakeet v3: 26.43%, reproduced on 2026-11-03) |
| Portuguese, spontaneous interviews (CAMOES) | `none` + `energyThreshold` + `fluidAudioParakeet@nemotronUnified` | 35.04% | not measured | 2026-11-01, on-device (best cloud: Groq + LLM correction, 36.13%, 2026-09-26) |
| Portuguese, short clips (CORAA), on-device | `standardDSP` + `energyThreshold` + `fluidAudioParakeet@nemotronUnified` | 14.54% | not measured | 2026-11-01 (Parakeet v3: 15.31%, 2026-09-26) |
| Portuguese, short clips (CORAA), cloud | `standardDSP` + `energyThreshold` + `whisperAPI:elevenLabs` | 12.50% | not measured | 2026-09-26 |
| Speaker turns (VoxConverse, en), on-device | `none` + `energyThreshold` + `fluidAudio@nemotron3` | — | 4.44% (raw **1.39%**) | 2026-11-01, same run as Pyannote's 13.13% (raw 10.61%) |

The AMI on-device row stays on Parakeet v3, the shipped FluidAudio ASR
default. On the same code Phonon-2 ties it on WER (22.35–24.73% against
22.27–23.85%) and is ~2.3–2.6pp ahead on fused DER, which is inside what four
meetings can tell apart; it is also English-only. With Nemotron 3 instead of
Pyannote, the speaker-attributed transcript improves far more than any ASR
swap moves it (cpWER ~25% against ~33%).

On AMI — the corpus that matches what the app records — Parakeet leads the
established on-device engines on both metrics at once: ~4pp WER over Groq
turbo and ~4pp over whisper.cpp `largeTurbo` at their best (2026-11-03). In the cloud, ElevenLabs Scribe is
the most accurate recognizer measured on meetings and on CORAA (~6pp WER
under Parakeet on AMI), and with its own diarization it produces the best
speaker-attributed transcript measured: cpWER ~17% against ~35% for the same
words attributed by `fluidAudio` (Pyannote). CAMOES remains the one corpus where no
cloud model beats Groq + correction. Portuguese has no single winner: the per-corpus rows reverse
each other, so the aggregate is a property of the corpus mix, not of an
engine.

In Portuguese the picture changed on 2026-11-01: Nemotron Unified, on device,
leads every engine measured on CAMOES and aggregate Portuguese, and is within
2pp of ElevenLabs on CORAA. It is also the weakest of the new models in English
(28.07% on AMI), so it is a per-language choice, not a new default.

**How this lines up with the app's shipped defaults.** Preprocessing
(`.standardDSP`), VAD (`.energyThreshold`), diarization (`.fluidAudio`) and
correction (`.none`) all match the best measured option, or the evidence
supports them. The transcription default (`.appleSpeech`) does not — not
because it measured worse, but because **it has never measured at all** (see
the open question above). Every number in this file is an alternative to the
shipped default rather than the default itself.

### Diarizers head to head, same run (supersedes the table below)

2026-09-26, Parakeet ASR, raw DER (the diarizer's own turns, ±0.25 s) —
constant across preprocessing × VAD, since the diarizer reads its own copy:

| Corpus | `fluidAudio` | `sherpaOnnx` | `heuristic` |
| --- | --- | --- | --- |
| AMI (4 meetings, 4 speakers each) | **18.28%** | 37.41% | 49.92–78.27% |
| VoxConverse (4 files, first run) | **10.62%** | 23.32% | 30.54–40.94% |

`fluidAudio@nemotron3` (Nemotron 3, 2026-11-01) on VoxConverse: **1.39%**.
Raw DER does not depend on the ASR engine, and Pyannote reproduced its 10.62%
as 10.61% in that run, so the comparison holds across the two dates. On AMI
(2026-11-03) it is **28.26%**, against Pyannote's 18.08% on the same code:
almost all missed speech (197.9 s of 762.1 s), with less than half Pyannote's
confusion (12.6 s against 28.5 s), and cpWER ~8pp better.

This settles D4 as far as these eight files go: the segmentation-first
engine is about twice FluidAudio's error on both corpora. FluidAudio's VBx
step still collapses to two centroids on a four-speaker AMI meeting
(`TS3003a`: 141/10 assignment) and still scores 11.7% there, so the
collapse is real but not what dominates DER on this material.

### D4 per file: sherpa-onnx never holds where Pyannote collapses

The roadmap's question was narrower than the aggregate: does any single
recording show Pyannote collapsing while sherpa-onnx holds? Raw DER per file,
2026-09-26 (`none` + `energyThreshold`; confusion seconds in brackets):

| File | `fluidAudio` (Pyannote) | `sherpaOnnx` | `heuristic` | `fluidAudio@nemotron3` (2026-11-01 / 2026-11-03) |
| --- | --- | --- | --- | --- |
| VoxConverse `0000` | 32.2% (81.1 s) | 45.0% (112.2 s) | 61.2% (142.8 s) | **2.5% (0.0 s)** |
| VoxConverse `0001` | 3.6% | 4.1% | 48.9% | 0.3% |
| VoxConverse `0002` | 1.1% | 0.8% | 3.3% | 0.7% |
| VoxConverse `0003` | 5.8% | 49.1% | 54.5% | 2.2% |
| AMI `EN2002a` | 31.1% | 45.4% | 67.7% | 26.7% (0.8 s) |
| AMI `ES2004a` | 9.4% | 28.1% | 119.9% | 29.4% |
| AMI `IS1009a` | 13.4% | 24.0% | 76.4% | 24.4% |
| AMI `TS3003a` | 11.7% | 42.4% | 67.4% | 32.0% |

`voxconverse-en-0000` is the one file where Pyannote's clustering visibly
fails, and sherpa-onnx confuses **more** speech there, not less. It is ahead
on one file, by 0.3pp. So no file supports the reason the engine was added;
by the roadmap's own rule it is a candidate for removal. The files that do
recover are Nemotron 3's: VoxConverse `0000` and AMI `EN2002a`, Pyannote's two
worst (confusion 0.8 s against 23.8 s on `EN2002a`). On the other three AMI
meetings Nemotron 3 is worse than Pyannote, by missing speech rather than
confusing it.

### sherpa-onnx vs. FluidAudio: the diarizer axis, ASR held constant

The 2026-08-27 run swept `sherpaOnnx` alone, so it looks like it cannot be
compared against `fluidAudio`. It can, for one specific reason: **its English
WER is bit-identical to the 2026-08-03 `whisperCpp@small` + `fluidAudio` rows
in all four configurations** (35.25% / 27.34% / 41.91% / 25.84%). `TranscriptFusion`
is word-preserving, so the diarizer cannot move WER — identical WER across
two runs is evidence that the ASR path behaved identically in both. The ASR
spans fusion attributes are therefore the same, and the fused-DER difference
is attributable to the diarizer.

AMI (4 meetings), `whisperCpp@small`, DER (fused) — lower is better:

| Preprocessing | VAD | `fluidAudio` | `sherpaOnnx` | `heuristic` |
| --- | --- | --- | --- | --- |
| none | energyThreshold | **44.65%** | 63.12% | 81.58% |
| none | fluidAudio | **47.22%** | 65.27% | 75.37% |
| standardDSP | energyThreshold | **49.59%** | 67.44% | 89.04% |
| standardDSP | fluidAudio | **49.67%** | 67.22% | 72.22% |

`sherpaOnnx` sits consistently ~17–18pp behind `fluidAudio` and ~10–20pp
ahead of `heuristic`, in every configuration. It is a real diarizer, not a
degenerate one — but on this material it does not beat the default.

**What this does and does not settle.** D4's bar is collapse-resistance
specifically: whether the segmentation-first pipeline holds up on the
far-field files where FluidAudio's VBx step collapses everyone into one
speaker. FluidAudio's 44–50% here is not a collapse pattern, so these four
meetings may simply not exercise that failure — an engine cannot demonstrate
resistance to a failure that did not occur. What the table does establish is
that `sherpaOnnx` is not a general-purpose improvement, so adopting it as
anything other than an opt-in alternative would need evidence this run does
not contain. The per-file numbers that would settle it are in the run's
`report.csv`; the aggregate cannot.

*Caveats: cross-run (different commits), and fused DER rather than raw —
`fluidAudio` has no recorded raw-turn DER, since D2 landed after 2026-08-03.
A same-run dispatch with `diarization_engines: fluidAudio,sherpaOnnx` would
give both raw numbers side by side and supersede this table.*

### The VAD choice swings Parakeet's DER by ~15pp while improving its WER

From the 2026-08-03 English rows, holding diarizer (`fluidAudio`) and ASR
(`fluidAudioParakeet`) constant and changing only the VAD engine:

| Preprocessing | VAD | WER | DER (fused) |
| --- | --- | --- | --- |
| none | energyThreshold | 21.94% | **32.88%** |
| none | fluidAudio | **19.83%** | 47.44% |
| standardDSP | energyThreshold | 21.19% | **32.89%** |
| standardDSP | fluidAudio | 21.94% | 50.19% |

Switching to the FluidAudio (Silero) VAD *improves* WER on the `none` row
while degrading fused DER by ~15pp. Right words, worse timings — which is
the signature of a timeline problem rather than a recognition one, since
fused DER is scored on span boundaries and WER is not.

Worth investigating, as a lead rather than a diagnosis: the VAD engine gates
what reaches the transcriber, and when compaction runs the spans come back on
the compacted timeline and are remapped through `CompactionResult.map`. A
remap that is slightly off would produce exactly this pattern. Two things
argue for looking there rather than at the diarizer: the diarizer reads its
own separately-cleaned copy and never sees the VAD's output at all, and the
same axis moved `sherpaOnnx`'s fused DER by only ~2pp in the 2026-08-27 run
(63.12% → 65.27%), so whatever this is, it is specific to the span
granularity a given ASR engine produces. Starting points: `VADAudioCompactor`,
`CompactionResult.map`, and whether `TranscriptFusion.splitCoarseSpan` (the
fallback used when word timestamps are absent) is being hit more often on
this path.

### Correction pays off only where the engine reports confidence

Recorded in full in the 2026-08-09 entry; restated here because it is a
standing property of the stage rather than a fact about one run.
`LLMTranscriptCorrector.isEligible` sends *every* non-empty segment when the
engine exposes no per-token confidence (Apple Speech, FluidAudio Parakeet),
and only low-confidence segments when it does (whisper.cpp, cloud Whisper).
The measured consequence: the gated path produced the only real improvements
(CORAA −2.04pp, CAMOES −1.46pp), while the ungated path was flat-to-worse in
**every** configuration measured (up to +0.73pp). "Correct everything" and
"correct what the decoder is unsure about" are not the same feature.

The 2026-11-05 pair reproduced it on Nemotron Unified (no confidence, so every
segment is sent): the old corrector was worse in English in all four
configurations (+0.36 to +0.86pp) and the topic-critique corrector that
replaced it was too (+0.50 to +0.61pp), while both gained a little in
Portuguese. Neither the critique, the neighbouring context nor the
faithfulness check (which blocks *added* words, not removed ones) changes
that the ungated path corrects speech that was already right.

## Runs

### 2026-11-06 — `b8d6db1` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/42229034531))

**sherpa-onnx 2.x produces real multi-speaker turns; raw DER has not
regressed against 1.x.** This successful dispatch ran on `origin/main` HEAD,
with sherpa-onnx **2.0.1** (bumped from 1.13.8 in `3c86aeb`, 2026-10-31),
`sherpaOnnx` diarization and `fluidAudioParakeet` ASR on all four AMI meetings.
`matrix: full` swept `none` / `standardDSP` preprocessing ×
`energyThreshold` / `fluidAudio` VAD.

The job log reports the same raw DER in every configuration (±0.25 s collar):

| File | Raw DER | Output turns | Output speakers |
| --- | --- | --- | --- |
| EN2002a | 45.4% | 42 | 16 |
| ES2004a | 28.1% | 17 | 5 |
| IS1009a | 24.0% | 24 | 10 |
| TS3003a | 42.4% | 29 | 7 |

The unweighted mean of those displayed per-file rates is **≈34.98%**.
This is not the corpus metric: the harness reports micro-averaged raw DER
of **37.41%** across the four meetings in all four configurations, exactly
matching **37.41%** on sherpa-onnx **1.13.8** in the 2026-09-26 Parakeet run.
The per-file rates also exactly reproduce the existing D4 per-file table
above (its sherpa-onnx column is the 2026-09-26 baseline; the Nemotron column
was added from the November runs). Raw DER scores the diarizer's own turns
before ASR fusion and is ASR-independent.

The logged turn and speaker counts establish that the 2.x C API executed
real diarization, not the single-speaker fallback. They do not establish
accurate speaker counts: sherpa-onnx still oversegments these meetings.

### 2026-11-05 — `3a81c91` vs `21c414a`: LLM correction before and after the topic critique

[Old corrector, `main` @ `3a81c91`](https://github.com/carlosmazzei/Kurn/actions/runs/42097203848) ·
[new corrector, branch @ `21c414a`](https://github.com/carlosmazzei/Kurn/actions/runs/42097769947)

**The question:** does the rewrite in #312 — a critic pass that infers the
meeting's topic and flags misheard terms, neighbouring speech and confidence
sent with each segment, and `CorrectionFaithfulness` rejecting corrections
that introduce unspoken words — move WER where the frequency-list corrector
did not? Two dispatches with identical inputs, one per corrector, each with
`correction: on`, so every configuration has an uncorrected row and a
corrected twin. The twin is a separate matrix entry that transcribes the
same input again (`PipelineEvaluationMatrix`), not a correction applied to
the uncorrected row's transcript.

**Why the cross-run comparison holds:** the uncorrected rows are identical to
the hundredth in both runs (every language and corpus, all four
configurations, WER and DER). That is strong evidence, not proof at full
precision, that ASR, diarization and scoring were deterministic, so the twin
re-transcribed what its uncorrected row did and the two runs differ only in
the corrector. The corrected
rows are not deterministic — they depend on LLM replies, whose run-to-run
spread was **not** measured here — so differences of ~0.5pp between the two
correctors are within what a second dispatch could move.

**Answer: no measurable improvement.**

- **English is still made worse by correction**, slightly less than before:
  +0.54pp on average across the four configurations (old: +0.63pp), AMI
  +0.58pp (old +0.67pp), AMI cpWER +0.35pp (old +0.45pp). The one regression
  the old corrector introduced on LibriSpeech (0.53% → 1.05%) is gone.
- **Portuguese gains less**: −0.38pp on average (old −0.68pp). CAMOES keeps
  its gain (−0.91pp, old −1.00pp); CORAA loses it (0.00pp, old −0.45pp) and
  goes up 0.51pp in one configuration.
- DER is unchanged by either corrector, as it must be (text only).
- Not measured: aggregate substitution/insertion/deletion counts (the job log
  prints them per item only and the artifact is unreachable from here), so
  the cause of the English regression — most likely the LLM tidying
  disfluencies AMI's verbatim reference keeps, which `CorrectionFaithfulness`
  does not block because it removes words rather than adding them — is a
  hypothesis, not a measurement.

Setup, both runs: matrix `full` filtered to `fluidAudioParakeet@nemotronUnified`
(prep `none`/`standardDSP` × VAD `energyThreshold`/`fluidAudio`),
diarization `fluidAudio@pyannote`, no cloud ASR, correction `on` with
OpenAI's default model, 720 scored rows each; reference-tool re-score matched
each CSV to 0.0000pp.

Configurations: **A** none + energyThreshold · **B** none + fluidAudio ·
**C** standardDSP + energyThreshold · **D** standardDSP + fluidAudio. Each
cell is *no correction / old corrector / new corrector*.

#### By language

| Language | A | B | C | D |
| --- | --- | --- | --- | --- |
| English (10 items) | 26.20 / 27.06 / 26.70 | 26.70 / 27.38 / 27.24 | 26.95 / 27.56 / 27.56 | 27.49 / 27.85 / 27.99 |
| Portuguese (80 items) | 23.87 / 23.27 / 23.57 | 24.62 / 24.62 / 24.17 | 24.02 / 23.12 / 23.42 | 24.17 / 22.97 / 24.02 |

#### By corpus

| Corpus | A | B | C | D |
| --- | --- | --- | --- | --- |
| AMI WER | 28.07 / 28.96 / 28.61 | 28.61 / 29.34 / 29.19 | 28.88 / 29.53 / 29.53 | 29.45 / 29.84 / 29.99 |
| AMI WER (standard) | 26.06 / 26.74 / 26.38 | 26.70 / 27.30 / 27.26 | 25.93 / 26.50 / 26.58 | 26.62 / 26.98 / 27.14 |
| AMI cpWER | 33.32 / 33.84 / 33.48 | 34.73 / 35.21 / 35.13 | 34.32 / 34.73 / 34.81 | 34.52 / 34.89 / 34.89 |
| AMI DER fused / raw (±0.25 s) | 29.68 / 18.11 | 34.15 / 18.11 | 31.49 / 18.11 | 39.83 / 18.11 |
| LibriSpeech | 0.53 / 1.05 / 0.53 | 0.53 / 0.53 / 0.53 | 0.53 / 0.53 / 0.53 | 0.53 / 0.53 / 0.53 |
| CAMOES | 35.04 / 33.94 / 34.67 | 35.40 / 35.77 / 34.31 | 37.59 / 36.13 / 36.50 | 37.59 / 35.77 / 36.50 |
| CORAA | 16.07 / 15.82 / 15.82 | 17.09 / 16.84 / 17.09 | 14.54 / 14.03 / 14.29 | 14.80 / 14.03 / 15.31 |

#### Change versus no correction (pp, mean of A–D)

| | Old corrector | New corrector |
| --- | --- | --- |
| English | +0.63 | +0.54 |
| Portuguese | −0.68 | −0.38 |
| AMI WER | +0.67 | +0.58 |
| AMI cpWER | +0.45 | +0.35 |
| CAMOES | −1.00 | −0.91 |
| CORAA | −0.45 | 0.00 |

> The tables in the entries for 2026-11-01 and 2026-11-03 below were rebuilt from the job logs,
> because the `pipeline-eval-report` artifacts live on blob storage this
> environment cannot reach. WER counts are exact; the log prints DER seconds
> to 0.1 s, so a DER here can differ from the harness's by up to ~0.05pp. Each
> run's reference-tool re-score matched its own CSV to 0.0000pp.


### 2026-11-03 — `5cfc919` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41702642987))

**Groq `whisper-large-v3` and `whisper-large-v3-turbo` on all four AMI
meetings.** The 2026-11-01 turbo dispatch got one AMI meeting through the
mirror; this one got all four, with the fetch retries from `5cfc919`.

- **Turbo is the better of the two Groq models on meetings**: 26.38–28.46% AMI
  WER against 28.34–29.84% for `whisper-large-v3`, with fused DER 28.47–42.34%
  against 36.08–45.20%. Both are behind Parakeet v3 on device (22.27–23.85%,
  same code).
- **cpWER 34.73–35.93%** for both, about the same as Parakeet + Pyannote
  (33.28–33.96%). The words are worse, and the attribution is just as bad.
- LibriSpeech 0.53% for every turbo cell and the two `none` v3 cells (1.05%
  with `standardDSP`), as with every strong engine on read speech.

- matrix: full (8 configuration(s))
- preprocessing: standardDSP, none
- VAD: energyThreshold, fluidAudio
- diarization: fluidAudio
- on-device ASR: appleSpeech, fluidAudioParakeet, whisperCpp
- whisper.cpp models: small
- FluidAudio ASR models: parakeetV3
- FluidAudio diarization models: pyannote
- cloud mode: groq
- cloud ASR providers: Groq
- LLM correction: off
- total: 8 configuration(s) x 10 item(s) = ~80 run(s)
- corpora:
  - AMI Meeting Corpus (Mix-Headset, first 5 min) (english, 4 item(s), WER+DER) [CC BY 4.0 (AMI Corpus, audio + manual annotation); MIT (pyannote/AMI-diarization-setup RTTM)]
  - LibriSpeech test-clean (english, 6 item(s), WER) [CC BY 4.0]
- 80 scored (item, configuration) row(s)

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 24.62% | 10 | 28.47% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 25.23% | 10 | 29.52% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 25.45% | 10 | 42.34% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq | 26.49% | 10 | 38.80% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 26.56% | 10 | 32.82% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | whisperAPI:groq | 26.66% | 10 | 37.33% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | whisperAPI:groq | 27.34% | 10 | 36.08% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq | 27.88% | 10 | 45.20% | 4 | 18.08% | 4 |

<details><summary>Per corpus</summary>

##### english / ami-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 26.38% | 4 | 28.47% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 27.04% | 4 | 29.52% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 27.27% | 4 | 42.34% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq | 28.34% | 4 | 38.80% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 28.46% | 4 | 32.82% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | whisperAPI:groq | 28.57% | 4 | 37.33% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | whisperAPI:groq | 29.30% | 4 | 36.08% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq | 29.84% | 4 | 45.20% | 4 | 18.08% | 4 |

##### english / librispeech-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperAPI:groq | 0.53% | 6 |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 0.53% | 6 |
| none | fluidAudio | fluidAudio | whisperAPI:groq | 0.53% | 6 |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq | 1.05% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq | 1.05% | 6 |

</details>

### 2026-11-03 — `5cfc919` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41699664893))

**whisper.cpp `small` on LibriSpeech, the one cell the README table was
missing.** 1.05% in all four configurations, against 0.53% for `base`,
`largeTurbo` and Parakeet. Read speech separates nothing at this size: one
extra error over 6 files.

- matrix: full (4 configuration(s))
- preprocessing: standardDSP, none
- VAD: energyThreshold, fluidAudio
- diarization: fluidAudio
- on-device ASR: appleSpeech, fluidAudioParakeet, whisperCpp
- whisper.cpp models: small
- FluidAudio ASR models: parakeetV3
- FluidAudio diarization models: pyannote
- cloud mode: none
- cloud ASR providers: none
- LLM correction: off
- total: 4 configuration(s) x 6 item(s) = ~24 run(s)
- corpora:
  - LibriSpeech test-clean (english, 6 item(s), WER) [CC BY 4.0]
- 24 scored (item, configuration) row(s)

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperCpp@small | 1.05% | 6 |
| none | fluidAudio | fluidAudio | whisperCpp@small | 1.05% | 6 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@small | 1.05% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@small | 1.05% | 6 |

### 2026-11-03 — `5cfc919` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41699659363))

**ElevenLabs `scribe_v1` against `scribe_v2`, same run, with both diarization
choices, on all four AMI meetings.** The 2026-11-01 `scribe_v2` run was DER-only
on three meetings because AMI's annotation zip returned 403; this is the first
`scribe_v2` WER on meetings.

- **The two models tie on words**: `scribe_v1` 15.86–16.94% and `scribe_v2`
  16.01–17.55% AMI WER (14.44–16.12% standard). The difference between them is
  inside the spread one model shows across VAD and preprocessing.
- **Native diarization still gives the best speaker-attributed transcript
  measured**: cpWER **17.06%** (`scribe_v2`, `none` + Silero VAD) and 17.66%
  (`scribe_v1`, same configuration), against 34.28–36.09% when the same words
  are attributed by Pyannote. That reproduces the 2026-09-26 finding
  (18.19–18.47%).
- **The native turns swing with the VAD choice**: cpWER rises to 19.47–27.58%
  and raw DER to 41.92–46.25% with `energyThreshold`. Silero VAD is the
  setting to use with native diarization.
- **Fused DER with Pyannote dropped to 19.0–20.1%**, from 32.26% on 2026-09-26,
  while Pyannote's raw DER stayed 18.08%. The diarizer did not change, so the
  drop is the fusion fix that landed between the two runs, not the recognizer.

- matrix: full (16 configuration(s))
- preprocessing: standardDSP, none
- VAD: energyThreshold, fluidAudio
- diarization: fluidAudio, transcriptionProviderNative
- on-device ASR: appleSpeech, fluidAudioParakeet, whisperCpp
- whisper.cpp models: small
- FluidAudio ASR models: parakeetV3
- FluidAudio diarization models: pyannote
- cloud mode: elevenlabs
- cloud ASR providers: ElevenLabs
- LLM correction: off
- total: 16 configuration(s) x 4 item(s) = ~64 run(s)
- corpora:
  - AMI Meeting Corpus (Mix-Headset, first 5 min) (english, 4 item(s), WER+DER) [CC BY 4.0 (AMI Corpus, audio + manual annotation); MIT (pyannote/AMI-diarization-setup RTTM)]
- 64 scored (item, configuration) row(s)

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:elevenLabs | 15.86% | 4 | 19.73% | 4 | 18.08% | 4 |
| none | fluidAudio | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | 16.01% | 4 | 18.54% | 4 | 33.55% | 4 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 16.01% | 4 | 19.60% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | transcriptionProviderNative | whisperAPI:elevenLabs | 16.21% | 4 | 19.32% | 4 | 43.17% | 4 |
| none | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 16.24% | 4 | 20.09% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | whisperAPI:elevenLabs | 16.28% | 4 | 19.84% | 4 | 18.08% | 4 |
| none | fluidAudio | transcriptionProviderNative | whisperAPI:elevenLabs | 16.55% | 4 | 18.30% | 4 | 33.08% | 4 |
| none | energyThreshold | fluidAudio | whisperAPI:elevenLabs | 16.71% | 4 | 19.13% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 16.71% | 4 | 19.80% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:elevenLabs | 16.74% | 4 | 20.00% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | 16.82% | 4 | 22.39% | 4 | 35.11% | 4 |
| standardDSP | fluidAudio | transcriptionProviderNative | whisperAPI:elevenLabs | 16.90% | 4 | 18.88% | 4 | 31.51% | 4 |
| none | energyThreshold | transcriptionProviderNative | whisperAPI:elevenLabs | 16.94% | 4 | 22.11% | 4 | 46.25% | 4 |
| none | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 16.97% | 4 | 19.01% | 4 | 18.08% | 4 |
| none | energyThreshold | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | 16.97% | 4 | 18.86% | 4 | 41.91% | 4 |
| standardDSP | energyThreshold | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | 17.55% | 4 | 21.93% | 4 | 45.60% | 4 |

### 2026-11-03 — `5cfc919` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41694750856))

**Nemotron 3 diarization on AMI, the measurement the 2026-11-01 VoxConverse run
left open.** Parakeet v3 and Phonon-2 ASR, so the result can be read against
the same-code Pyannote run below.

- **Raw DER is worse than Pyannote: 28.26% against 18.08%** (25.43% in one
  cell, the run's only non-constant raw DER, so Nemotron 3 is not fully
  deterministic on the runner). Over the four meetings, 197.9 s of 762.1 s
  reference speech is **missed** (Pyannote: 97.4 s), with 4.9 s false alarm
  (11.9 s) and only **12.6 s confusion** (28.5 s). Nemotron 3 drops overlapped
  and quiet speech, but assigns what it keeps to the right speaker more often.
- **That trade is what a reader of the transcript sees, and it wins**:
  cpWER **24.49–27.22%** with Parakeet against 33.28–33.96% for Pyannote, same
  ASR and same words. Fusion still attributes every word to the nearest turn,
  so missed speech costs few words while confusion costs whole utterances.
- **Fused DER 20.30–22.99% with `energyThreshold`**, against Pyannote's
  24.66–25.01%. Silero VAD makes it 29.6–49.0%, the same VAD penalty the
  fused DER shows for every diarizer on Parakeet.
- **Per file** (D4 table): it fixes Pyannote's worst meeting, `EN2002a`
  (confusion 0.8 s against 23.8 s), and is worse on the other three, where
  Pyannote had little confusion to remove.
- No voiceprints and an eight-speaker ceiling still apply (CLAUDE.md,
  "Choosing the diarizer"), so it is not a drop-in default.

- matrix: full (8 configuration(s))
- preprocessing: standardDSP, none
- VAD: energyThreshold, fluidAudio
- diarization: fluidAudio
- on-device ASR: appleSpeech, fluidAudioParakeet, whisperCpp
- whisper.cpp models: small
- FluidAudio ASR models: parakeetV3, phonon2
- FluidAudio diarization models: nemotron3
- cloud mode: none
- cloud ASR providers: none
- LLM correction: off
- total: 8 configuration(s) x 4 item(s) = ~32 run(s)
- corpora:
  - AMI Meeting Corpus (Mix-Headset, first 5 min) (english, 4 item(s), WER+DER) [CC BY 4.0 (AMI Corpus, audio + manual annotation); MIT (pyannote/AMI-diarization-setup RTTM)]
- 32 scored (item, configuration) row(s)

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | fluidAudio | fluidAudio@nemotron3 | fluidAudioParakeet | 21.31% | 4 | 42.05% | 4 | 28.26% | 4 |
| standardDSP | energyThreshold | fluidAudio@nemotron3 | fluidAudioParakeet | 22.27% | 4 | 22.74% | 4 | 25.43% | 4 |
| none | fluidAudio | fluidAudio@nemotron3 | fluidAudioParakeet@phonon2 | 22.35% | 4 | 29.71% | 4 | 28.26% | 4 |
| standardDSP | energyThreshold | fluidAudio@nemotron3 | fluidAudioParakeet@phonon2 | 22.43% | 4 | 20.44% | 4 | 28.26% | 4 |
| standardDSP | fluidAudio | fluidAudio@nemotron3 | fluidAudioParakeet@phonon2 | 23.46% | 4 | 29.58% | 4 | 28.26% | 4 |
| none | energyThreshold | fluidAudio@nemotron3 | fluidAudioParakeet | 23.58% | 4 | 22.99% | 4 | 28.26% | 4 |
| standardDSP | fluidAudio | fluidAudio@nemotron3 | fluidAudioParakeet | 23.85% | 4 | 48.97% | 4 | 28.26% | 4 |
| none | energyThreshold | fluidAudio@nemotron3 | fluidAudioParakeet@phonon2 | 24.73% | 4 | 20.30% | 4 | 28.26% | 4 |

### 2026-11-03 — `5cfc919` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41693250571))

**Parakeet v3 in Portuguese on the current code**, to check that Nemotron
Unified's lead from 2026-11-01 is not a code difference.

- **It reproduced 2026-09-26 exactly**: 26.43–27.48% aggregate, CAMOES
  42.34–42.70%, CORAA 15.31–17.09%. Nothing between the two commits changed
  Parakeet's Portuguese output.
- So Nemotron Unified's 23.87% aggregate, 35.04% on CAMOES and 14.54% on CORAA
  (2026-11-01) stand as a same-code lead: ~2.6pp on aggregate, ~7pp on CAMOES,
  ~0.8pp on CORAA.

- matrix: full (4 configuration(s))
- preprocessing: standardDSP, none
- VAD: energyThreshold, fluidAudio
- diarization: fluidAudio
- on-device ASR: appleSpeech, fluidAudioParakeet, whisperCpp
- whisper.cpp models: small
- FluidAudio ASR models: parakeetV3
- FluidAudio diarization models: pyannote
- cloud mode: none
- cloud ASR providers: none
- LLM correction: off
- total: 4 configuration(s) x 80 item(s) = ~320 run(s)
- corpora:
  - CAMOES Sociolinguistic Interviews (pt) (portuguese, 40 item(s), WER) [CC BY 4.0]
  - CORAA v1.1 (pt) (portuguese, 40 item(s), WER) [CC BY-NC-ND 4.0]
- 320 scored (item, configuration) row(s)

#### Portuguese

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 26.43% | 80 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 27.18% | 80 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 27.33% | 80 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 27.48% | 80 |

<details><summary>Per corpus</summary>

##### portuguese / camoes-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 42.34% | 40 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 42.34% | 40 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 42.34% | 40 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 42.70% | 40 |

##### portuguese / coraa-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 15.31% | 40 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 16.58% | 40 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 16.58% | 40 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 17.09% | 40 |

</details>

### 2026-11-03 — `5cfc919` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41693244971))

**Parakeet v3 and whisper.cpp `largeTurbo` on all four AMI meetings, on the
current code.** Two questions: does Parakeet v3's fused DER fall like the new
models' did after the fusion fix, and what does `largeTurbo` score on meetings
(the 2026-11-01 dispatch was DER-only on three).

- **Parakeet v3: 20.79–22.01% English WER (AMI 22.27–23.58% with
  `energyThreshold`), fused DER 24.66–25.01%** against 33.26% on 2026-09-26.
  Raw DER is unchanged (18.08%), so the fusion fix accounts for the drop. The
  2026-11-01 Phonon-2 (22.07%) and Bark 3.0 (26.25%) fused DER can now be read
  against this: Phonon-2 is ~2.6pp ahead of Parakeet on fused DER at the same
  WER (also ~2.3pp ahead with Nemotron 3 in the run above), Bark 3.0 ~1.6pp
  behind.
- **cpWER 33.28–33.96%** for every Parakeet cell. The attribution, not the
  words, is what a reader of a Pyannote transcript loses.
- **whisper.cpp `largeTurbo` on AMI: 26.00–46.27% WER.** The spread is
  hallucination: 530 insertions over 2,604 reference words with `none` +
  `energyThreshold`, 49 with `standardDSP` + Silero VAD. Behind Parakeet on
  every cell; best with `standardDSP` + Silero VAD (26.00%, cpWER 36.17%).
- LibriSpeech 0.53% for both engines in every cell.
- The run took 4h30m of the 6h ceiling; `largeTurbo` is the slowest engine
  in the matrix.

- matrix: full (8 configuration(s))
- preprocessing: standardDSP, none
- VAD: energyThreshold, fluidAudio
- diarization: fluidAudio
- on-device ASR: appleSpeech, fluidAudioParakeet, whisperCpp
- whisper.cpp models: largeTurbo
- FluidAudio ASR models: parakeetV3
- FluidAudio diarization models: pyannote
- cloud mode: none
- cloud ASR providers: none
- LLM correction: off
- total: 8 configuration(s) x 10 item(s) = ~80 run(s)
- corpora:
  - AMI Meeting Corpus (Mix-Headset, first 5 min) (english, 4 item(s), WER+DER) [CC BY 4.0 (AMI Corpus, audio + manual annotation); MIT (pyannote/AMI-diarization-setup RTTM)]
  - LibriSpeech test-clean (english, 6 item(s), WER) [CC BY 4.0]
- 80 scored (item, configuration) row(s)

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 19.90% | 10 | 44.89% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 20.79% | 10 | 24.66% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 22.01% | 10 | 25.01% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 22.26% | 10 | 51.03% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 24.27% | 10 | 31.40% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 27.42% | 10 | 35.74% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 31.21% | 10 | 42.79% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 43.16% | 10 | 52.30% | 4 | 18.08% | 4 |

<details><summary>Per corpus</summary>

##### english / ami-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 21.31% | 4 | 44.89% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 22.27% | 4 | 24.66% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 23.58% | 4 | 25.01% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 23.85% | 4 | 51.03% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 26.00% | 4 | 31.40% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 29.38% | 4 | 35.74% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 33.45% | 4 | 42.79% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 46.27% | 4 | 52.30% | 4 | 18.08% | 4 |

##### english / librispeech-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 0.53% | 6 |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 0.53% | 6 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 |

</details>


### 2026-11-01 — `aebf04e` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41339676563))

**First measurement of Nemotron 3 diarization, against Pyannote in the same
run.** VoxConverse only: AMI's mirror refused every meeting that afternoon, and
the first dispatch of this comparison (`41336079434`) failed in the fetch step
before anything ran (see "AMI's mirror throttles CI runners" in
`Tools/evaluation/public_datasets/README.md`).

- **Raw DER 1.39% against Pyannote's 10.61%.** Pyannote reproduced its
  2026-09-26 figure (10.62%), so the comparison stands. Fused DER is
  4.44–7.45% against 13.13–15.93%.
- **Most of the gap is one recording.** On `voxconverse-en-0000` Pyannote
  confused 81.1 s of 265.6 s (32.2% raw) and Nemotron 3 none (2.5%). On the
  other three files Nemotron 3 is ahead by 0.4–3.6pp or level.
- **The eight-speaker ceiling did not bite here.** `voxconverse-en-0001` has 12
  reference speakers in its first five minutes and scored 0.3% raw; the
  speakers beyond eight carry little speech in that clip.
- **It costs about twice the time** (≈110 s per five-minute file on the runner
  against 55–65 s) and returns no voiceprints, so speaker identity matching is
  unavailable with it (CLAUDE.md, "Speaker identity").
- Four files are a signal, not a verdict. AMI is the next measurement.

#### English

| Preprocessing | VAD | Diarization | ASR | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio@nemotron3 | fluidAudioParakeet | 4.44% | 4 | 1.39% | 4 |
| standardDSP | energyThreshold | fluidAudio@nemotron3 | fluidAudioParakeet | 6.64% | 4 | 1.39% | 4 |
| none | fluidAudio | fluidAudio@nemotron3 | fluidAudioParakeet | 6.88% | 4 | 1.39% | 4 |
| standardDSP | fluidAudio | fluidAudio@nemotron3 | fluidAudioParakeet | 7.45% | 4 | 1.39% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 13.13% | 4 | 10.61% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 15.02% | 4 | 10.61% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 15.20% | 4 | 10.61% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 15.93% | 4 | 10.61% | 4 |

### 2026-11-01 — `f6745bb` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41336072736))

**First measurement of the five FluidAudio ASR models added in `2ccd8b6`**
(Nemotron Unified, Bark 3.0, Bark 3.0 Clean, Phonon-2, Nemotron 3.5 Transcribe
Lite), with the Pyannote diarizer. AMI came down in full: 4 meetings, WER and DER.

- **Phonon-2 and Bark 3.0 tie Parakeet v3 on WER**: best AMI 22.35% and
  22.43% against Parakeet's 21.31–24.31% on 2026-09-26. Transcribe Lite is
  close (23.00%); Nemotron Unified (28.07%) and Bark 3.0 Clean (30.34%) are
  behind in English.
- **Transcribe Lite regresses on read speech**: 5.26–6.84% on LibriSpeech
  against 0.53% for every other model. It also has the lowest fused DER
  (21.88%) but the worst cpWER (35.77–36.97%): its word ends are estimated
  from the next word's start (CLAUDE.md, "Word timestamps"), so boundaries
  land well and words do not.
- **Fused DER looks ~10pp better than Parakeet's 33.26%** (Phonon-2 22.07%,
  Bark 3.0 26.25%), but that compares across the fusion timing/break fix
  merged between the two runs. Raw DER (18.08% here, 18.28% on 2026-09-26)
  shows the diarizer itself is unchanged; a same-code Parakeet run is needed
  before crediting the model.
- **The FluidAudio VAD inflates fused DER for every model** (30–46% against
  22–31% with `energyThreshold`), as recorded for Parakeet before.
- cpWER (re-scored, `none` + `energyThreshold`): Bark 3.0 32.76%, Nemotron
  Unified 33.32%, Phonon-2 34.36%, Bark 3.0 Clean 34.36%, Transcribe Lite
  36.97%.

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@phonon2 | 20.87% | 10 | 31.43% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@bark3 | 20.94% | 10 | 26.27% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@phonon2 | 20.94% | 10 | 22.08% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@bark3 | 21.80% | 10 | 41.28% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 21.80% | 10 | 21.99% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@phonon2 | 21.90% | 10 | 30.40% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 22.15% | 10 | 45.68% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@bark3 | 22.19% | 10 | 26.91% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 22.26% | 10 | 45.41% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@bark3 | 22.33% | 10 | 41.88% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 22.73% | 10 | 21.86% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@phonon2 | 23.09% | 10 | 22.29% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 26.20% | 10 | 29.68% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 26.70% | 10 | 34.17% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 26.95% | 10 | 31.49% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 27.49% | 10 | 39.81% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@bark3Clean | 28.31% | 10 | 27.82% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@bark3Clean | 28.56% | 10 | 28.91% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@bark3Clean | 29.31% | 10 | 44.11% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@bark3Clean | 30.14% | 10 | 44.05% | 4 | 18.08% | 4 |

<details><summary>Per corpus</summary>

##### english / ami-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@phonon2 | 22.35% | 4 | 31.43% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@bark3 | 22.43% | 4 | 26.27% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@phonon2 | 22.43% | 4 | 22.08% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 23.00% | 4 | 21.99% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@bark3 | 23.35% | 4 | 41.28% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 23.39% | 4 | 45.41% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 23.39% | 4 | 45.68% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@phonon2 | 23.46% | 4 | 30.40% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@bark3 | 23.77% | 4 | 26.91% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 23.89% | 4 | 21.86% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@bark3 | 23.92% | 4 | 41.88% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@phonon2 | 24.73% | 4 | 22.29% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 28.07% | 4 | 29.68% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 28.61% | 4 | 34.17% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 28.88% | 4 | 31.49% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 29.45% | 4 | 39.81% | 4 | 18.08% | 4 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@bark3Clean | 30.34% | 4 | 27.82% | 4 | 18.08% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@bark3Clean | 30.61% | 4 | 28.91% | 4 | 18.08% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@bark3Clean | 31.41% | 4 | 44.11% | 4 | 18.08% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@bark3Clean | 32.30% | 4 | 44.05% | 4 | 18.08% | 4 |

##### english / librispeech-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@bark3 | 0.53% | 6 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@bark3Clean | 0.53% | 6 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 0.53% | 6 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@phonon2 | 0.53% | 6 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@bark3 | 0.53% | 6 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@bark3Clean | 0.53% | 6 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 0.53% | 6 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@phonon2 | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@bark3 | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@bark3Clean | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@phonon2 | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@bark3 | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@bark3Clean | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@phonon2 | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 5.26% | 6 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 5.26% | 6 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 6.84% | 6 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronTranscribeLite | 6.84% | 6 |

</details>

### 2026-11-01 — `f6745bb` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41336076180))

**Nemotron Unified in Portuguese**, the only new FluidAudio model that accepts
`pt` (the others are English-only and skip these corpora).

- **The best Portuguese on-device result recorded**: 23.87–24.62% aggregate
  against Parakeet's best of 26.43% (2026-09-26).
- **CAMOES 35.04–37.59%** is 5–7pp better than Parakeet (42.34–42.70%) and
  beats every cloud model measured, including Groq + correction (36.13%).
- CORAA 14.54–17.09% overlaps Parakeet's 15.31–17.09%.
- The comparison crosses runs, but the diarizer cannot move WER and the CAMOES
  gap is well above the ~2pp noise floor. A same-code Parakeet dispatch is
  queued to confirm.

#### Portuguese

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 23.87% | 80 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 24.02% | 80 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 24.17% | 80 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 24.62% | 80 |

<details><summary>Per corpus</summary>

##### portuguese / camoes-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 35.04% | 40 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 35.40% | 40 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 37.59% | 40 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 37.59% | 40 |

##### portuguese / coraa-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 14.54% | 40 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 14.80% | 40 |
| none | energyThreshold | fluidAudio | fluidAudioParakeet@nemotronUnified | 16.07% | 40 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet@nemotronUnified | 17.09% | 40 |

</details>

### 2026-11-01 — `f6745bb` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41336081989))

**whisper.cpp `base` and `largeTurbo`, English.** AMI is DER-only on 3
meetings here: the mirror refused the manual-annotation zip and one meeting's
audio. `largeTurbo` matches every strong model on LibriSpeech (0.53%); `base`
is 2.11–2.63%.

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 | 64.72% | 3 | 21.00% | 3 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 | 44.02% | 3 | 21.00% | 3 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 | 53.13% | 3 | 21.00% | 3 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 | 38.53% | 3 | 21.00% | 3 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 2.11% | 6 | 48.39% | 3 | 21.00% | 3 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 2.11% | 6 | 48.95% | 3 | 21.00% | 3 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 2.63% | 6 | 44.06% | 3 | 21.00% | 3 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 2.63% | 6 | 59.42% | 3 | 21.00% | 3 |

<details><summary>Per corpus</summary>

##### english / ami-en

| Preprocessing | VAD | Diarization | ASR | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 38.53% | 3 | 21.00% | 3 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 44.02% | 3 | 21.00% | 3 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 44.06% | 3 | 21.00% | 3 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 48.39% | 3 | 21.00% | 3 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 48.95% | 3 | 21.00% | 3 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 53.13% | 3 | 21.00% | 3 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 59.42% | 3 | 21.00% | 3 |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 64.72% | 3 | 21.00% | 3 |

##### english / librispeech-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 2.11% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 2.11% | 6 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 2.63% | 6 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 2.63% | 6 |

</details>

### 2026-11-01 — `f6745bb` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41336084871))

**whisper.cpp `base` and `largeTurbo`, Portuguese.**

- **`largeTurbo` is 10–14pp better than `small`**: CAMOES 40.51–40.88%
  (`small` 54.38–58.76% on 2026-08-09) and CORAA 19.39–20.66% (`small`
  29.08–31.38%). It still trails Nemotron Unified (35.04% / 14.54%).
- `base` is not usable for Portuguese: CAMOES 72.99–74.09%, CORAA
  44.13–44.64%.

#### Portuguese

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 28.23% | 80 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 28.38% | 80 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 28.68% | 80 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 28.98% | 80 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 56.01% | 80 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 56.31% | 80 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 56.46% | 80 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 56.61% | 80 |

<details><summary>Per corpus</summary>

##### portuguese / camoes-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 40.51% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 40.51% | 40 |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 40.88% | 40 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 40.88% | 40 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 72.99% | 40 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 72.99% | 40 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 74.09% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 74.09% | 40 |

##### portuguese / coraa-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 19.39% | 40 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@largeTurbo | 19.90% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 20.41% | 40 |
| none | fluidAudio | fluidAudio | whisperCpp@largeTurbo | 20.66% | 40 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 44.13% | 40 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 44.13% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 44.39% | 40 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 44.64% | 40 |

</details>

### 2026-11-01 — `f6745bb` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41336088010))

**Groq `whisper-large-v3-turbo`**, against `whisper-large-v3` from 2026-08-03
(cross-run, so a signal only). AMI covers **one meeting** (`TS3003a`); the mirror
refused the other three, so the AMI rows are not comparable with any 4-meeting
figure.

- CAMOES 40.51–43.43% is 2.5–5.5pp worse than v3's 37.96%; CORAA
  20.66–21.94% is within noise of v3's 22.45%. Nothing here argues for
  changing Groq's default model.
- LibriSpeech 0.53%. All 348 cells ran with no rate limit.

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 14.11% | 7 | 16.76% | 1 | 11.10% | 1 |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 14.61% | 7 | 13.46% | 1 | 11.10% | 1 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 15.36% | 7 | 14.75% | 1 | 11.10% | 1 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 15.98% | 7 | 14.62% | 1 | 11.10% | 1 |

#### Portuguese

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 28.83% | 80 |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 29.58% | 80 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 30.03% | 80 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 30.33% | 80 |

<details><summary>Per corpus</summary>

##### english / ami-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 18.33% | 1 | 16.76% | 1 | 11.10% | 1 |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 18.99% | 1 | 13.46% | 1 | 11.10% | 1 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 19.97% | 1 | 14.75% | 1 | 11.10% | 1 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 20.79% | 1 | 14.62% | 1 | 11.10% | 1 |

##### english / librispeech-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 0.53% | 6 |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 0.53% | 6 |

##### portuguese / camoes-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 40.51% | 40 |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 40.51% | 40 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 43.43% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 43.43% | 40 |

##### portuguese / coraa-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 20.66% | 40 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 20.66% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 21.17% | 40 |
| none | fluidAudio | fluidAudio | whisperAPI:groq@whisper-large-v3-turbo | 21.94% | 40 |

</details>

### 2026-11-01 — `924702e` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41315829712))

**whisper.cpp `base` with all three local diarizers.** The one dispatch of the
`924702e` batch that completed: AMI came down for 3 meetings (DER) and 2 of them
with a transcript (WER).

- Raw DER on those 3 meetings: `fluidAudio` 21.03%, `sherpaOnnx` 35.33%,
  `heuristic` 57.51–82.81% — the same ordering as 2026-09-26.
- `base` WER is the weakest on-device figure measured: AMI 31.50–37.83%,
  CAMOES 73.72–75.18%, CORAA 44.39–44.90%.

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 28.32% | 8 | 48.39% | 3 | 21.00% | 3 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 31.28% | 8 | 59.42% | 3 | 21.00% | 3 |
| standardDSP | energyThreshold | heuristic | whisperCpp@base | 31.50% | 2 | 82.35% | 3 | 82.82% | 3 |
| standardDSP | energyThreshold | sherpaOnnx | whisperCpp@base | 31.50% | 2 | 60.22% | 3 | 35.32% | 3 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 31.62% | 8 | 45.14% | 3 | 21.00% | 3 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 33.96% | 8 | 48.95% | 3 | 21.00% | 3 |
| none | energyThreshold | heuristic | whisperCpp@base | 34.38% | 2 | 78.74% | 3 | 82.82% | 3 |
| none | energyThreshold | sherpaOnnx | whisperCpp@base | 34.38% | 2 | 56.70% | 3 | 35.32% | 3 |
| none | fluidAudio | heuristic | whisperCpp@base | 34.76% | 2 | 87.47% | 3 | 62.27% | 3 |
| none | fluidAudio | sherpaOnnx | whisperCpp@base | 34.76% | 2 | 71.17% | 3 | 35.32% | 3 |
| standardDSP | fluidAudio | heuristic | whisperCpp@base | 37.83% | 2 | 75.15% | 3 | 57.56% | 3 |
| standardDSP | fluidAudio | sherpaOnnx | whisperCpp@base | 37.83% | 2 | 61.15% | 3 | 35.32% | 3 |

#### Portuguese

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 56.46% | 80 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 56.76% | 80 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 56.91% | 80 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 57.06% | 80 |

<details><summary>Per corpus</summary>

##### english / ami-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 31.50% | 2 | 48.39% | 3 | 21.00% | 3 |
| standardDSP | energyThreshold | heuristic | whisperCpp@base | 31.50% | 2 | 82.35% | 3 | 82.82% | 3 |
| standardDSP | energyThreshold | sherpaOnnx | whisperCpp@base | 31.50% | 2 | 60.22% | 3 | 35.32% | 3 |
| none | energyThreshold | heuristic | whisperCpp@base | 34.38% | 2 | 78.74% | 3 | 82.82% | 3 |
| none | energyThreshold | sherpaOnnx | whisperCpp@base | 34.38% | 2 | 56.70% | 3 | 35.32% | 3 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 34.76% | 2 | 59.42% | 3 | 21.00% | 3 |
| none | fluidAudio | heuristic | whisperCpp@base | 34.76% | 2 | 87.47% | 3 | 62.27% | 3 |
| none | fluidAudio | sherpaOnnx | whisperCpp@base | 34.76% | 2 | 71.17% | 3 | 35.32% | 3 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 35.14% | 2 | 45.14% | 3 | 21.00% | 3 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 37.83% | 2 | 48.95% | 3 | 21.00% | 3 |
| standardDSP | fluidAudio | heuristic | whisperCpp@base | 37.83% | 2 | 75.15% | 3 | 57.56% | 3 |
| standardDSP | fluidAudio | sherpaOnnx | whisperCpp@base | 37.83% | 2 | 61.15% | 3 | 35.32% | 3 |

##### english / librispeech-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 2.11% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 2.11% | 6 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 2.63% | 6 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 2.63% | 6 |

##### portuguese / camoes-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | fluidAudio | fluidAudio | whisperCpp@base | 73.72% | 40 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 73.72% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 74.45% | 40 |
| none | energyThreshold | fluidAudio | whisperCpp@base | 75.18% | 40 |

##### portuguese / coraa-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperCpp@base | 44.39% | 40 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@base | 44.39% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@base | 44.64% | 40 |
| none | fluidAudio | fluidAudio | whisperCpp@base | 44.90% | 40 |

</details>

### 2026-11-01 — `924702e` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/41305791412))

**First measurement of ElevenLabs `scribe_v2`.** It was added to the
transcription model list with `scribe_v1` still the default; this run asks
whether it should become the default. Short answer: not on this evidence.

Read this run with three limits in mind:

- **No AMI WER and no cpWER.** The AMI server (`groups.inf.ed.ac.uk`)
  returned HTTP 403 for the manual-annotation zip, so `fetch_ami.py` fell back
  to DER only, as designed. The 403 also cost one meeting's audio
  (`TS3003a`), so AMI DER here covers **3 meetings, not 4**, and is not
  comparable with the 4-meeting rows of earlier runs.
- **The comparison with `scribe_v1` crosses runs**: 162 commits between
  `5ae7fed` and `924702e`, including the fusion timing/break fix. The
  diarizer cannot move WER, so the WER comparison is a fair signal; DER is
  not.
- Three other dispatches from the same batch (whisper.cpp `base` and
  `largeTurbo`, Groq `whisper-large-v3-turbo`) were cancelled before
  scoring anything. A `base` dispatch two hours later completed and is
  recorded above; `largeTurbo` and Groq turbo were measured at `f6745bb`.

What it says:

- **WER is level with `scribe_v1`, not better.** LibriSpeech is the same
  0.53%. CAMOES is 43.43–47.45% (v1: 42.70–47.08%) and CORAA is 13.01–13.78%
  (v1: 12.50–13.78%). Every range overlaps, and v1 holds the best figure on
  both Portuguese corpora. The reference-tool re-score matches the harness to
  0.0000pp.
- **Native turns keep the same shape as with `scribe_v1`**: worst on raw DER
  (40.58–53.48% against 21.03% for `fluidAudio`), yet the best fused DER
  measured here (21.20%, `none` + FluidAudio VAD). That gap is why cpWER was
  the deciding metric on 2026-09-26, and this run could not measure it.
- **`standardDSP` + `energyThreshold` is the outlier on fused DER** for both
  diarizers (31.48% and 32.54%, against 21–28% for the other three
  combinations), while the raw `fluidAudio` DER is identical in all four.
  Three meetings are too few to tell this apart from noise.

#### English

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 0.53% | 6 | 23.95% | 3 | 21.03% | 3 |
| none | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 0.53% | 6 | 23.74% | 3 | 21.03% | 3 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 0.53% | 6 | 31.48% | 3 | 21.03% | 3 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 0.53% | 6 | 23.26% | 3 | 21.03% | 3 |
| none | fluidAudio | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | — | — | 21.20% | 3 | 40.58% | 3 |
| none | energyThreshold | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | — | — | 22.05% | 3 | 53.46% | 3 |
| standardDSP | fluidAudio | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | — | — | 27.70% | 3 | 43.48% | 3 |
| standardDSP | energyThreshold | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | — | — | 32.54% | 3 | 53.48% | 3 |

#### Portuguese

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 25.53% | 80 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 26.73% | 80 |
| none | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 27.03% | 80 |
| none | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 27.63% | 80 |

<details><summary>Per corpus</summary>

##### english / ami-en

| Preprocessing | VAD | Diarization | ASR | DER (fused) | DER (fused) items | DER (raw) | DER (raw) items |
| --- | --- | --- | --- | --- | --- | --- | --- |
| none | fluidAudio | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | 21.20% | 3 | 40.58% | 3 |
| none | energyThreshold | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | 22.05% | 3 | 53.46% | 3 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 23.26% | 3 | 21.03% | 3 |
| none | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 23.74% | 3 | 21.03% | 3 |
| none | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 23.95% | 3 | 21.03% | 3 |
| standardDSP | fluidAudio | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | 27.70% | 3 | 43.48% | 3 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 31.48% | 3 | 21.03% | 3 |
| standardDSP | energyThreshold | transcriptionProviderNative | whisperAPI:elevenLabs@scribe_v2 | 32.54% | 3 | 53.48% | 3 |

##### english / librispeech-en

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 0.53% | 6 |
| none | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 0.53% | 6 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 0.53% | 6 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 0.53% | 6 |

##### portuguese / camoes-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 43.43% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 45.62% | 40 |
| none | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 46.35% | 40 |
| none | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 47.45% | 40 |

##### portuguese / coraa-pt

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 13.01% | 40 |
| none | energyThreshold | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 13.52% | 40 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 13.52% | 40 |
| none | fluidAudio | fluidAudio | whisperAPI:elevenLabs@scribe_v2 | 13.78% | 40 |

</details>


### 2026-09-26 — `986697b`…`5ae7fed` (nine dispatches, linked under Runs at a glance)

**First run of the reference-tool re-scoring, the first VoxConverse measurement,
a same-run diarizer comparison, and the first OpenAI models beyond `whisper-1`.**
The dispatches ran on consecutive commits of one branch; the pipeline code
differs between them only in the three fixes named below (untimed spans,
whitespace-only spans, provider turns under compaction), each of which moves
only the cloud rows it names.

Measurement fixes in the same branch, before any number here:

- DER's speaker mapping was exhaustive up to seven labels and **greedy** above
  that. Against `pyannote.metrics` on random 8–12-speaker timelines the greedy
  branch over-reported DER in 3 of 4 cases (up to ~8pp). Now Hungarian —
  matters for VoxConverse (up to 21 speakers) and any 8-label heuristic run.
  Earlier runs never had more than seven labels on either side, so their DER
  is unaffected.
- `transcriptionProviderNative` was swept against on-device engines, where it
  silently runs `heuristic`; those duplicate cells are gone.

#### Diarization (Parakeet ASR)

See "Diarizers head to head" under Cross-run findings for raw DER. Fused DER
(AMI, 4 meetings):

| Preprocessing | VAD | `fluidAudio` | `sherpaOnnx` | `heuristic` |
| --- | --- | --- | --- | --- |
| none | energyThreshold | 34.00% | 46.52% | 67.17% |
| none | fluidAudio | 48.00% | 62.96% | 73.25% |
| standardDSP | energyThreshold | **33.26%** | 46.87% | 67.51% |
| standardDSP | fluidAudio | 50.23% | 65.98% | 69.30% |

The FluidAudio VAD adds ~15pp of fused DER with every diarizer while raw DER
is unchanged — the VAD/compaction timeline lead in Cross-run findings, now
reproduced in a single run.

VoxConverse (4 files, 5 min each, DER only): `fluidAudio` 13.70–15.89% fused /
10.62% raw; `sherpaOnnx` 24.60–26.67% / 23.32%; `heuristic` 31.84–39.97% /
30.54–40.94%.

#### On-device baseline (fluidAudio diarizer)

Parakeet: AMI 21.31–24.31% WER, LibriSpeech 0.53%, CAMOES 42.34–42.70%,
CORAA 15.31–17.09%. whisper.cpp `small` reproduced its 2026-08-27 WER in all
four configurations. Apple Speech: skipped in every cell (see open questions).

#### Cloud: OpenAI (fluidAudio diarizer)

WER (harness normalizer), range over preprocessing × VAD:

| Corpus | `whisper-1` | `gpt-4o-transcribe` | `gpt-4o-mini-transcribe` |
| --- | --- | --- | --- |
| AMI | 30.45–31.91% | 26.34–69.70% | **24.31–28.96%** |
| LibriSpeech | 3.16–3.91% | 0.53–1.05% | **0.53–1.05%** |
| CAMOES | **39.11–45.26%** | 46.35–58.03% | 46.35–51.82% |
| CORAA | 18.96–21.68% | 27.04–31.38% | **17.69–22.05%** |

AMI after the fix, re-scored with the reference tools (`none` + `energyThreshold`):

| Model | WER | WER standard | cpWER | DER fused ±0.25 s | DER fused, no collar |
| --- | --- | --- | --- | --- | --- |
| `whisper-1` | 31.91% | 26.69% | 38.58% | 32.05% | 38.95% |
| `gpt-4o-mini-transcribe` | 24.35% | **19.05%** | 39.14% | 24.72% | 31.80% |
| `gpt-4o-transcribe` | 33.53% | 28.38% | 48.74% | 24.72% | 31.80% |

What this says:

- **`gpt-4o-*` scored 100% fused DER before the fix.** Both models return
  plain text with no timings; `OpenAIProvider` emitted one zero-length span
  per chunk, so every word of up to ten minutes sat on one instant and was
  given to one speaker. `WhisperTranscriber` now gives such spans the chunk's
  extent. Any user on those models had effectively single-speaker transcripts.
- **`gpt-4o-mini-transcribe` is the best English cloud model; `gpt-4o-transcribe`
  is erratic** (26–70% on AMI across configurations, never best in
  Portuguese). On CAMOES `whisper-1` wins.
- **~5pp of AMI WER is formatting.** The standard normalizer removes fillers
  and normalizes numbers; AMI's manual transcript keeps "um"/"uh" and spells
  numbers out. LibriSpeech and the Portuguese corpora do not move.
- **cpWER is 7–15pp above WER**: that gap is speaker-attribution error in the
  text a user reads, the one thing neither WER nor DER shows alone.
- **9 of 1080 cells failed** — 6 `emptySegmentText` (a model returned `""`
  for a clip with no intelligible speech and the integrity gate rejected the
  whole transcript; fixed after this run by dropping whitespace-only spans)
  and 3 `ambiguousProviderResult` (upload interrupted; not retried on
  purpose, to avoid double billing).

A confirmation dispatch on `37def97` (`whisper-1` and `gpt-4o-mini-transcribe`,
CAMOES + CORAA only) ran all 640 cells with **no failures** after the
whitespace-span fix, scored only the two selected corpora, and its rescore
cross-check matched the harness to 0.0000pp on WER and DER.

#### Cloud: ElevenLabs Scribe (`scribe_v1`)

WER, range over preprocessing × VAD (harness normalizer): AMI **15.67–16.90%**
(14.39–15.43% standard), LibriSpeech 0.53%, CAMOES 42.70–47.08%, CORAA
**12.50–13.78%** — the best AMI and CORAA figures in this file.

AMI speaker attribution, after the compaction fix (`5ae7fed`), re-scored:

| Preprocessing | VAD | Diarization | cpWER | DER fused ±0.25 s | DER raw ±0.25 s |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | `fluidAudio` | 34.68% | 34.17% | 18.28% |
| none | energyThreshold | native | 26.62% | 37.45% | 45.48% |
| none | fluidAudio | `fluidAudio` | 33.64% | 37.16% | 18.28% |
| none | fluidAudio | native | **18.19%** | 28.08% | 33.95% |
| standardDSP | energyThreshold | `fluidAudio` | 33.88% | 38.13% | 18.28% |
| standardDSP | energyThreshold | native | 26.29% | 41.26% | 42.70% |
| standardDSP | fluidAudio | `fluidAudio` | 33.28% | 29.00% | 18.28% |
| standardDSP | fluidAudio | native | **18.47%** | 24.72% | 31.26% |

What this says:

- **The native turns were being thrown away.** Before `5ae7fed` the native
  rows with the FluidAudio VAD scored 64.25% raw DER and 55% cpWER: when VAD
  compaction ran, `transcribeGated` rebuilt the transcript from spans alone
  and dropped the provider's `speakerTurns`, so diarization fell back to one
  synthetic speaker. They are now remapped with the spans.
- **Raw DER and cpWER disagree, and cpWER is the one a user reads.**
  `fluidAudio`'s turns are closer to the reference (18% raw DER), but
  ElevenLabs attributes each word itself, so the text lands with the right
  speaker far more often (cpWER 18% vs 33%). A local diarizer's turns are
  only as useful as the word timings used to fuse text onto them.
- **Native results move with the VAD** (cpWER 18% vs 26%) even though the
  provider diarizes the audio it receives — compaction removes silence the
  provider would otherwise have to segment around. Worth a per-file look
  before recommending a default.

#### Cloud: Groq `whisper-large-v3` + LLM correction (OpenAI)

All 360 cells ran; no rate limit this time. Against the uncorrected 2026-08-03
Groq rows (cross-run, so a signal only): English −0.15 to +1.82pp, Portuguese
−0.60 to +0.45pp — a wash in aggregate, as with whisper.cpp. Per corpus,
CAMOES with `standardDSP` reached **36.13%**, the best CAMOES figure recorded.

### 2026-08-27 — `6f0a094` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/33029297796))

**First runtime measurement of the sherpa-onnx diarization engine (D4)** — the
segmentation-first alternative to FluidAudio's cluster-first VBx pipeline
(`docs/roadmap.md`, D4). Also the first recorded run to report
`DER (raw)` alongside `DER (fused)`, now that D2's raw-turn metric exists in
the harness output.

Scope is deliberately narrow: `KURN_PUBLIC_EVAL_DIARIZATION_ENGINES=sherpaOnnx`
(the new engine only — not compared against `fluidAudio` in this same
dispatch) and `whisperCpp@small` as the sole transcription engine. **This run
answers "does the new engine run for real and produce a real number", not yet
"is it more collapse-resistant than FluidAudio"** — that needs a same-run
comparison, noted below.

As with the 2026-08-03 entry, the `pipeline-eval-report` artifact's download
URL (Azure Blob Storage) is blocked by this environment's network policy, so
this section is built from the harness's own aggregate log output
(`[pipeline-eval] === aggregate ... ===`) rather than re-derived with
`report_to_markdown.py` against the raw CSV. A maintainer with normal network
access can download artifact id `9631144328` from the run above and
regenerate byte-for-byte.

- matrix: 4 configurations (preprocessing × VAD), diarization fixed to
  `sherpaOnnx`, transcription fixed to `whisperCpp@small`.
- corpora: the same four as prior runs — AMI Meeting Corpus (en, 4 meetings,
  WER+DER), LibriSpeech test-clean (en, 6 items, WER), CAMOES (pt, 40 items,
  WER), CORAA (pt, 40 items, WER).

#### English by language (AMI + LibriSpeech, 10 files; AMI DER over 4)

| Preprocessing | VAD | WER | DER (fused) | DER (raw) |
| --- | --- | --- | --- | --- |
| none | energyThreshold | 35.25% | 63.12% | 37.41% |
| none | fluidAudio | 27.34% | 65.27% | 37.41% |
| standardDSP | energyThreshold | 41.91% | 67.44% | 37.41% |
| standardDSP | fluidAudio | 25.84% | 67.22% | 37.41% |

#### Portuguese by language (CAMOES + CORAA, 80 files)

| Preprocessing | VAD | WER |
| --- | --- | --- |
| none | energyThreshold | 42.49% |
| none | fluidAudio | 41.14% |
| standardDSP | energyThreshold | 40.54% |
| standardDSP | fluidAudio | 40.99% |

#### By corpus

`english/ami-en` (4 meetings — real, multi-speaker meeting audio):

| Preprocessing | VAD | WER | DER (fused) | DER (raw) |
| --- | --- | --- | --- | --- |
| none | energyThreshold | 37.75% | 63.12% | 37.41% |
| none | fluidAudio | 29.26% | 65.27% | 37.41% |
| standardDSP | energyThreshold | 44.89% | 67.44% | 37.41% |
| standardDSP | fluidAudio | 27.65% | 67.22% | 37.41% |

`english/librispeech-en` (6 items): 1.05% WER across all four
configurations — unchanged from prior runs, the regression canary still
holds.

`portuguese/camoes-pt` (40 items):

| Preprocessing | VAD | WER |
| --- | --- | --- |
| none | energyThreshold | 59.85% |
| none | fluidAudio | 57.66% |
| standardDSP | energyThreshold | 54.38% |
| standardDSP | fluidAudio | 54.38% |

`portuguese/coraa-pt` (40 items):

| Preprocessing | VAD | WER |
| --- | --- | --- |
| none | energyThreshold | 30.36% |
| none | fluidAudio | 29.59% |
| standardDSP | energyThreshold | 30.87% |
| standardDSP | fluidAudio | 31.63% |

What this run says:

- **The engine runs, for real, in CI.** The job log shows
  `SherpaOnnxDiarizer: processing ... complete in 0.08–0.92s` on every item,
  not the disabled `#else` stub's instant single-turn fallback — the
  bridging-header/`SHERPA_ONNX_ENABLED` wiring flagged as the remaining step
  when this engine was added is done.
- **DER (raw) is identical (37.41%) across all four preprocessing × VAD
  combinations on AMI** — expected, not a bug: diarization runs against its
  own cleaned copy (`diarizationPreprocessingEnabled`, fixed `true` here)
  independent of whatever preprocessing/VAD the ASR side used, so the
  diarizer sees the same input regardless. A good internal-consistency check
  on the measurement itself.
- **DER (fused) is substantially worse than DER (raw) here (63–67% vs.
  37.41%).** Fusion attributes whisper.cpp's ASR span boundaries to the
  diarizer's turns, so the fused number blends diarization error with ASR
  boundary placement — exactly the reason D2 added the raw-turn metric, and
  this gap is a clean demonstration of why "which diarizer is better" needs
  the raw number, not the fused one.
- **This is not yet the collapse-resistance verdict D4 asked for.** 37.41%
  raw DER on AMI is a real, non-degenerate number — not the ~100%-collapsed
  pattern a whole-meeting fallback would produce — but nothing in this
  dispatch measured `fluidAudio`'s raw DER on the same four meetings in the
  same run, so there is no same-run baseline to say whether sherpa-onnx
  actually resists the VBx collapse better. **Next step**: dispatch again
  with `diarization_engines: fluidAudio,sherpaOnnx` (or leave it blank for
  all three engines) so both raw DERs land in the same CSV and are directly
  comparable.
- WER moves with preprocessing/VAD in the same pattern prior whisper.cpp/small
  runs showed (compare the 2026-08-09 table) — expected, since diarization
  doesn't touch the transcript text.

### 2026-08-09 — `53db49c` ([essential+correction run](https://github.com/carlosmazzei/Kurn/actions/runs/31284831125), [Parakeet+correction run](https://github.com/carlosmazzei/Kurn/actions/runs/31307328299))

**First measurement of the opt-in LLM transcript-correction stage**
(`LLMTranscriptCorrector`, the `correction` input on `pipeline-eval.yml`).
Confidence-gated on engines that report a decoder confidence (whisper.cpp,
cloud Whisper) — only segments below `LLMTranscriptCorrector.lowConfidenceThreshold`
(0.85) are sent for correction; ungated on engines that don't (FluidAudio
Parakeet) — every non-empty segment is sent, since there's no signal to
filter on. `TranscriptCorrectionGuardrail` rejects any rewrite that changes
more than 35% of a segment's words. The stage runs after fusion, text-only,
so it should never move DER — the tables below confirm that held in every
row measured.

- matrix: `essential` (8 whisper.cpp/small configurations) doubled to 16 by
  `correction: on` — baseline row + corrected twin, same run, same items,
  so the pair below is a same-run apples-to-apples comparison. Separately,
  a `matrix: full` dispatch scoped to `transcription_engines: fluidAudioParakeet`
  with `correction: only` (replaces each of the 8 configurations with its
  corrected version, no baseline row) — compared here against the
  `fluidAudioParakeet` baseline already recorded in the 2026-08-03 entry
  below, since re-measuring an already-known baseline would just repeat
  real OpenAI API spend for no new information.
- corpora: same as 2026-08-03 — AMI Meeting Corpus (en, 4 meetings,
  WER+DER), LibriSpeech test-clean (en, 6 items, WER), CAMOES (pt, 40
  items, WER), CORAA (pt, 40 items, WER).
- correction provider: OpenAI (`gpt-5.4`, the account's configured summary
  model).
- A third dispatch, `whisperAPI:groq` scoped (`correction: only`),
  **failed** and is not included below: Groq's `whisper-large-v3` endpoint
  returned `429: Rate limit reached … RPM: Limit 20, Used 20` for 41 of 376
  rows before the harness's `#require(failures.isEmpty)` failed the run.
  Root cause is structural, not a one-off: `PipelineEvaluationMatrix.build`'s
  cloud-ASR loop sits inside the diarization loop, so the same
  preprocessing×VAD×provider combination gets transcribed via the paid API
  twice — once per diarization variant — even though diarization never
  affects the transcription call. Groq is the one remaining confidence-gated
  engine that hasn't been measured with correction; worth a retry once that
  redundant call is fixed, or with a dispatch scoped small enough to stay
  under 20 RPM.

#### whisper.cpp/small — English by language (AMI + LibriSpeech, 10 files; AMI DER over 4)

| Preprocessing | VAD | Diarization | WER (no correction) | WER (corrected) | ΔWER | DER |
| --- | --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | 35.25% | 35.22% | −0.03 | 44.65% |
| none | energyThreshold | heuristic | 37.75% | 37.86% | +0.11 | 81.58% |
| none | fluidAudio | fluidAudio | 27.34% | 27.38% | +0.04 | 47.22% |
| none | fluidAudio | heuristic | 29.26% | 29.30% | +0.04 | 75.37% |
| standardDSP | energyThreshold | fluidAudio | 41.91% | 41.91% | 0.00 | 49.59% |
| standardDSP | energyThreshold | heuristic | 44.89% | 45.05% | +0.16 | 89.04% |
| standardDSP | fluidAudio | fluidAudio | 25.84% | 25.88% | +0.04 | 49.67% |
| standardDSP | fluidAudio | heuristic | 27.65% | 27.69% | +0.04 | 72.22% |

*DER is identical between the "no correction" and "corrected" runs in every
row in this file — shown once per row rather than twice.*

#### whisper.cpp/small — Portuguese by language (CAMOES + CORAA, 80 files)

| Preprocessing | VAD | WER (no correction) | WER (corrected) | ΔWER |
| --- | --- | --- | --- | --- |
| none | energyThreshold | 41.44% | 39.64% | **−1.80** |
| none | fluidAudio | 40.84% | 40.99% | +0.15 |
| standardDSP | energyThreshold | 40.54% | 40.24% | −0.30 |
| standardDSP | fluidAudio | 40.99% | 40.99% | 0.00 |

#### whisper.cpp/small — Portuguese by corpus

`portuguese/camoes-pt` (40 items — spontaneous sociolinguistic interviews):

| Preprocessing | VAD | WER (no correction) | WER (corrected) | ΔWER |
| --- | --- | --- | --- | --- |
| none | energyThreshold | 58.76% | 57.30% | −1.46 |
| none | fluidAudio | 57.66% | 58.03% | +0.37 |
| standardDSP | energyThreshold | 54.38% | 53.65% | −0.73 |
| standardDSP | fluidAudio | 54.74% | 56.20% | **+1.46** |

`portuguese/coraa-pt` (40 items — short, pre-segmented clips):

| Preprocessing | VAD | WER (no correction) | WER (corrected) | ΔWER |
| --- | --- | --- | --- | --- |
| none | energyThreshold | 29.34% | 27.30% | **−2.04** |
| none | fluidAudio | 29.08% | 29.08% | 0.00 |
| standardDSP | energyThreshold | 30.87% | 30.87% | 0.00 |
| standardDSP | fluidAudio | 31.38% | 30.36% | −1.02 |

#### FluidAudio Parakeet — corrected-only vs. the 2026-08-03 baseline

English by language (10 files; DER over 4):

| Preprocessing | VAD | Diarization | WER (baseline) | WER (corrected) | ΔWER | DER |
| --- | --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | 21.94% | 22.51% | +0.57 | 32.88% |
| none | energyThreshold | heuristic | 23.50% | 24.23% | +0.73 | 67.19% |
| none | fluidAudio | fluidAudio | 19.83% | 19.94% | +0.11 | 47.44% |
| none | fluidAudio | heuristic | 21.24% | 21.89% | +0.65 | 73.33% |
| standardDSP | energyThreshold | fluidAudio | 21.19% | 21.19% | 0.00 | 32.89% |
| standardDSP | energyThreshold | heuristic | 22.70% | 23.43% | +0.73 | 67.76% |
| standardDSP | fluidAudio | fluidAudio | 21.94% | 21.94% | 0.00 | 50.19% |
| standardDSP | fluidAudio | heuristic | 23.50% | 23.92% | +0.42 | 69.34% |

Portuguese by language (80 files):

| Preprocessing | VAD | WER (baseline) | WER (corrected) | ΔWER |
| --- | --- | --- | --- | --- |
| none | energyThreshold | 26.58% | 26.73% | +0.15 |
| none | fluidAudio | 27.48% | 27.93% | +0.45 |
| standardDSP | energyThreshold | 27.18% | 26.58% | −0.60 |
| standardDSP | fluidAudio | 27.48% | 27.03% | −0.45 |

What this run says:

- **DER never moves, in either engine, in any configuration.** Confirms the
  stage's design goal: it rewrites `.text` only, after fusion, and never
  touches diarization or speaker attribution.
- **English never improves with correction, in either engine.** whisper.cpp
  is a wash (±0.16pp, noise); Parakeet is flat-to-worse in every single
  configuration (up to +0.73pp). Whisper's own English decode already has
  little left to fix, and Parakeet — with no confidence signal to gate on —
  sends every segment through the LLM regardless, so an accepted rewrite is
  pure downside risk with no accuracy left to gain back.
- **Confidence gating is what makes Portuguese correction pay off.**
  whisper.cpp (gated: only its weaker segments are sent) shows the only
  genuinely useful deltas — CORAA −2.04pp and −1.02pp, CAMOES −1.46pp and
  −0.73pp, never worse than +1.46pp. Parakeet (ungated: every segment is
  sent) is a wash on the same material, ±0.5pp with no clear direction —
  "correct everything" and "correct only what the decoder is unsure about"
  are not the same feature in practice, even sharing the same guardrail and
  prompt.
- **Whisper via Groq is still unmeasured with correction** — see the rate
  limit note above. It's the other confidence-gated engine, so the whisper.cpp
  result above is a reasonable but unconfirmed prior for how it would behave.
- **Sample sizes are the same as 2026-08-03** — treat the per-corpus swings
  on CAMOES/CORAA (40 items each) as directional, not settled.

### 2026-08-03 — `2644589` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/30800039020))

**First full-coverage run: English + Portuguese, WER and DER.** Both language
gaps in the previous entry are closed here — LibriSpeech and AMI ran
(`fetch_ami.py`'s rate-limit fix held), and the diarization axis is collapsed
on the Portuguese corpora (no reference RTTM there, so it can't move WER) per
the corpus-rebalance commits on this branch.

These numbers come straight from the harness's own `reportAggregate` log
output (rounded to two decimals), not from `report_to_markdown.py` against the
raw `report.csv`: the artifact lives on Azure Blob Storage, which this
evaluation environment's network policy blocks, so the CSV could not be
fetched to re-derive the tables from raw error counts. A maintainer with
normal network access can download the `pipeline-eval-report` artifact from
the run above and regenerate this section byte-for-byte with
`report_to_markdown.py` if the raw counts are wanted.

To do that: download the `pipeline-eval-report` artifact (id `8856661838`,
expires 2026-11-01) from the run above, unzip it into `report.csv` and
`pipeline-eval.log`, and run:

```bash
python3 Tools/evaluation/report_to_markdown.py \
  --csv report.csv --log pipeline-eval.log \
  --commit 264458909649b699619d49e031cf70fe1f71c2d2 \
  --run-url https://github.com/carlosmazzei/Kurn/actions/runs/30800039020 \
  --date 2026-08-03
```

- matrix: full — 24 on-device configurations (whisper.cpp restricted to the
  `small` model, the workflow's default) + 8 more for `whisperAPI:groq`
  (`cloud_providers: auto` found only `GROQ_API_KEY`, not `OPENAI_API_KEY`),
  32 total for English (AMI carries a reference RTTM, so the diarizer axis
  stays); Portuguese collapses to 16 configurations x however many the
  language-support check lets through per item.
- corpora: AMI Meeting Corpus (en), 4 meetings, WER+DER [CC BY 4.0 audio +
  manual annotation / MIT RTTM]; LibriSpeech test-clean (en), 6 items, WER
  only [CC BY 4.0]; CAMOES Sociolinguistic Interviews (pt), 40 items, WER only
  [CC BY 4.0]; CORAA v1.1 (pt), 40 items, WER only [CC BY-NC-ND 4.0].
- whisper.cpp model: `small` only (this dispatch did not request the model
  sweep).
- cloud ASR providers: Groq (`whisper-large-v3`) only.
- **Apple Speech produced zero rows, in either language.** It is not absent
  from the matrix (`PipelineEvaluationMatrix.all` builds it for every
  language), and the run had no failures (`#require(failures.isEmpty)` would
  have failed the test otherwise), so every Apple Speech attempt took the
  silent "unsupported language" skip path rather than throwing. The likely
  cause is `SFSpeechRecognizer.supportedLocales()` returning empty on this
  CI simulator (no on-device Speech assets provisioned in a headless runner),
  which would skip *every* locale, not just Portuguese — but this could not be
  confirmed: the retrievable job log only covers the final ~13 minutes of a
  ~3h51m run, and English's Apple Speech attempts ran hours earlier in it.
  **This means the app's actual default transcription engine has no measured
  row here** — every number below is an alternative to the default, not the
  default itself. Closing this gap (e.g. logging
  `SFSpeechRecognizer.supportedLocales().count` once at run start so it's
  diagnosable from the job summary alone) should come before any default
  changes based on this run.

#### English — by language (AMI + LibriSpeech, 10 files; AMI DER over 4)

| Preprocessing | VAD | Diarization | ASR | WER | WER items | DER | DER items |
| --- | --- | --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 21.94% | 10 | 32.88% | 4 |
| none | energyThreshold | fluidAudio | whisperAPI:groq | 26.27% | 10 | 42.94% | 4 |
| none | energyThreshold | fluidAudio | whisperCpp@small | 35.25% | 10 | 44.65% | 4 |
| none | energyThreshold | heuristic | fluidAudioParakeet | 23.50% | 4 | 67.19% | 4 |
| none | energyThreshold | heuristic | whisperAPI:groq | 28.03% | 4 | 78.67% | 4 |
| none | energyThreshold | heuristic | whisperCpp@small | 37.75% | 4 | 81.58% | 4 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 19.83% | 10 | 47.44% | 4 |
| none | fluidAudio | fluidAudio | whisperAPI:groq | 27.20% | 10 | 46.08% | 4 |
| none | fluidAudio | fluidAudio | whisperCpp@small | 27.34% | 10 | 47.22% | 4 |
| none | fluidAudio | heuristic | fluidAudioParakeet | 21.24% | 4 | 73.33% | 4 |
| none | fluidAudio | heuristic | whisperAPI:groq | 29.15% | 4 | 73.45% | 4 |
| none | fluidAudio | heuristic | whisperCpp@small | 29.26% | 4 | 75.37% | 4 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 21.19% | 10 | 32.89% | 4 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq | 26.06% | 10 | 47.56% | 4 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@small | 41.91% | 10 | 49.59% | 4 |
| standardDSP | energyThreshold | heuristic | fluidAudioParakeet | 22.70% | 4 | 67.76% | 4 |
| standardDSP | energyThreshold | heuristic | whisperAPI:groq | 27.84% | 4 | 83.84% | 4 |
| standardDSP | energyThreshold | heuristic | whisperCpp@small | 44.89% | 4 | 89.04% | 4 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 21.94% | 10 | 50.19% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq | 26.56% | 10 | 39.61% | 4 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@small | 25.84% | 10 | 49.67% | 4 |
| standardDSP | fluidAudio | heuristic | fluidAudioParakeet | 23.50% | 4 | 69.34% | 4 |
| standardDSP | fluidAudio | heuristic | whisperAPI:groq | 28.53% | 4 | 64.82% | 4 |
| standardDSP | fluidAudio | heuristic | whisperCpp@small | 27.65% | 4 | 72.22% | 4 |

#### Portuguese — by language (CAMOES + CORAA, 80 files; diarizer axis collapsed)

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 26.58% | 80 |
| none | energyThreshold | fluidAudio | whisperAPI:groq | 27.63% | 80 |
| none | energyThreshold | fluidAudio | whisperCpp@small | 42.04% | 80 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 27.48% | 80 |
| none | fluidAudio | fluidAudio | whisperAPI:groq | 28.38% | 80 |
| none | fluidAudio | fluidAudio | whisperCpp@small | 40.69% | 80 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 27.18% | 80 |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq | 28.83% | 80 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@small | 40.69% | 80 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 27.48% | 80 |
| standardDSP | fluidAudio | fluidAudio | whisperAPI:groq | 29.13% | 80 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp@small | 40.84% | 80 |

#### By corpus (the grain that actually matters here)

`english/ami-en` (4 meetings — real, multi-speaker meeting audio, the app's
actual use case):

| Preprocessing | VAD | Diarization | ASR | WER | DER |
| --- | --- | --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 22.70% | 32.89% |
| standardDSP | energyThreshold | fluidAudio | whisperAPI:groq | 27.92% | 47.56% |
| standardDSP | energyThreshold | fluidAudio | whisperCpp@small | 44.89% | 49.59% |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 23.50% | 32.88% |
| none | energyThreshold | fluidAudio | whisperAPI:groq | 28.15% | 42.94% |
| none | energyThreshold | fluidAudio | whisperCpp@small | 37.75% | 44.65% |

`english/librispeech-en` (6 items — clean read speech, a regression canary):
all three engines score 0.53–1.05% WER regardless of configuration — no
signal here beyond "the pipeline still works."

`portuguese/camoes-pt` (40 items — spontaneous sociolinguistic interviews):

| Preprocessing | VAD | ASR | WER |
| --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudioParakeet | 42.34% |
| standardDSP | energyThreshold | whisperAPI:groq | **37.96%** |
| standardDSP | energyThreshold | whisperCpp@small | 54.74% |

`portuguese/coraa-pt` (40 items — pre-segmented short utterances):

| Preprocessing | VAD | ASR | WER |
| --- | --- | --- | --- |
| standardDSP | energyThreshold | fluidAudioParakeet | **16.58%** |
| standardDSP | energyThreshold | whisperAPI:groq | 22.45% |
| standardDSP | energyThreshold | whisperCpp@small | 30.87% |

What this run says:

- **The Portuguese aggregate hides a reversal, not a verdict.** CAMOES and
  CORAA are weighted equally (40 each) but represent opposite regimes: on
  CAMOES's longer, spontaneous interview speech, Groq's `whisper-large-v3`
  beats Parakeet by ~4.4 points; on CORAA's short, pre-segmented clips,
  Parakeet beats Groq by ~5.9 points. The blended "Parakeet wins the
  Portuguese aggregate by 1.65 points" is real but is an artifact of the mix,
  not a property of either engine.
- **On real meeting audio (AMI), Parakeet wins clearly and it isn't close.**
  ~5 points of WER and ~15 points of DER ahead of Groq, ~20+ points ahead of
  whisper.cpp `small`. That's the corpus that matches what Kurn actually
  records, and it's also the one place the harness scores WER and DER
  together end to end. Worth noting Groq is not disadvantaged by the app's
  hallucination filter here — `TranscriptQualityFilter` only runs on Whisper
  output (cloud and whisper.cpp), never on Parakeet — so Parakeet's AMI lead
  isn't an artifact of asymmetric post-processing.
- **Preprocessing's effect is corpus-dependent, not just engine-dependent.**
  `standardDSP` helps whisper.cpp a lot on CAMOES (59.12%→54.74%) but slightly
  *hurts* all three engines on CORAA's already-clean clips, and hurts DER for
  whisper.cpp/Groq on AMI (44.65%→49.59%, 42.94%→47.56%) while leaving
  Parakeet's DER flat (32.88%→32.89%). There is still no global on/off answer;
  it now also depends on how clean the source recording already is.
- **The heuristic diarizer is far worse than fluidAudio's on DER** (67–89%
  vs. 33–50%), confirming the existing default choice — but even fluidAudio's
  best AMI DER here (32.88%) leaves roughly a third of speech misattributed,
  which is a real limitation to keep in view, not a solved problem.
- **Sample sizes are still modest.** 4 meetings and 40 short clips per
  Portuguese corpus are enough to trust the *direction* of a multi-point gap,
  not to treat a 1–2 point difference as settled. Apple Speech's absence
  (above) is the more urgent gap to close before any default changes.

### 2026-08-02 — `3eecdcc` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/30752932441))

**Partial coverage: Portuguese only, WER only.** The dispatch narrowed
`corpora` to the two Portuguese sets, so neither LibriSpeech (English WER) nor
AMI (English DER) ran. There is no English baseline and no DER figure yet.

This entry also predates two changes and is not directly comparable to later
runs: the corpus mix was rebalanced toward meeting audio afterwards, and the
per-corpus aggregate did not exist yet, so the numbers below blend CAMOES and
CORAA into one Portuguese total.

- matrix: full, restricted to Portuguese — 16 configuration(s) × 24 item(s) =
  384 scored rows
- corpora: CAMOES Sociolinguistic Interviews (pt), 12 items [CC BY 4.0];
  CORAA v1.1 (pt), 12 items [CC BY-NC-ND 4.0]
- whisper.cpp model: `small` (the default). This run predates the
  whisper.cpp model-sweep axis, so its labels carry no `@model` suffix.
- cloud ASR providers: none

| Preprocessing | VAD | Diarization | ASR | WER | WER items |
| --- | --- | --- | --- | --- | --- |
| none | energyThreshold | fluidAudio | fluidAudioParakeet | 28.57% | 24 |
| none | energyThreshold | heuristic | fluidAudioParakeet | 28.57% | 24 |
| none | fluidAudio | fluidAudio | fluidAudioParakeet | 28.57% | 24 |
| none | fluidAudio | heuristic | fluidAudioParakeet | 28.57% | 24 |
| standardDSP | energyThreshold | fluidAudio | fluidAudioParakeet | 32.28% | 24 |
| standardDSP | energyThreshold | heuristic | fluidAudioParakeet | 32.28% | 24 |
| standardDSP | fluidAudio | fluidAudio | fluidAudioParakeet | 32.28% | 24 |
| standardDSP | fluidAudio | heuristic | fluidAudioParakeet | 32.28% | 24 |
| standardDSP | energyThreshold | fluidAudio | whisperCpp | 42.33% | 24 |
| standardDSP | fluidAudio | heuristic | whisperCpp | 42.33% | 24 |
| standardDSP | energyThreshold | heuristic | whisperCpp | 42.86% | 24 |
| standardDSP | fluidAudio | fluidAudio | whisperCpp | 42.86% | 24 |
| none | energyThreshold | heuristic | whisperCpp | 47.09% | 24 |
| none | energyThreshold | fluidAudio | whisperCpp | 47.62% | 24 |
| none | fluidAudio | heuristic | whisperCpp | 49.21% | 24 |
| none | fluidAudio | fluidAudio | whisperCpp | 51.32% | 24 |

Skipped, and therefore absent from the table — a skip is not a 0%:

- `asr=appleSpeech` (8 configurations): Apple Speech is fixed to the device
  locale and does not serve Portuguese here.

What this run says:

- **Audio cleanup helps or hurts depending on the ASR engine.** `standardDSP`
  costs Parakeet 3.7 points (28.57% → 32.28%) and saves whisper.cpp 5 to 9
  (47.09–51.32% → 42.33–42.86%). There is no global "preprocessing on/off"
  answer, which is exactly the kind of thing a matrix exists to expose and a
  single-configuration run cannot.
- **Parakeet's WER is identical across every VAD and every diarizer.** That is
  expected, not a bug: diarization does not touch the words, and on clips this
  short VAD compaction did not change what reached the engine. The repetition
  in the table is the measurement agreeing with the architecture.
- **Nothing here justifies changing a default.** One dispatch, two corpora,
  24 short items, no English and no DER. It is a baseline to compare the next
  run against, not a verdict on the engines.
