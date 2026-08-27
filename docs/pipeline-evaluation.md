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

## Runs

### 2026-08-27 — `6f0a094` ([workflow run](https://github.com/carlosmazzei/Kurn/actions/runs/33029297796))

**First runtime measurement of the sherpa-onnx diarization engine (D4)** — the
segmentation-first alternative to FluidAudio's cluster-first VBx pipeline
(`docs/roadmap.md`, item D4). Also the first recorded run to report
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
