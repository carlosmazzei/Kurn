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
- **Every rate is micro-averaged over the corpus**: total errors divided by
  total reference, not the mean of the per-file rates. A short file with one
  bad word cannot dominate.
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

## Runs

### 2026-08-02 — `3eecdcc` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/30752932441))

**Partial coverage: Portuguese only, WER only.** The dispatch narrowed
`corpora` to the two Portuguese sets, so neither LibriSpeech (English WER) nor
AMI (English DER) ran. There is no English baseline and no DER figure yet.

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
