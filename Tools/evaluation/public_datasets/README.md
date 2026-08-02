# Public-dataset pipeline evaluation

`Tools/evaluation/README.md` covers measuring accuracy on your own recordings,
which cannot leave your machine. This directory is the other half: fetching
public benchmark audio (no privacy restriction, but still not committed --
see below) to run through the app's actual pipeline,
`PipelineEvaluationMatrix`'s full sweep of cleanup/VAD/diarization/ASR-engine
combinations, scoring WER and DER against each. It is what answers "did this
change to the diarizer/preprocessor/whichever actually help", with a number
instead of an inference from the literature.

Two ways to run it:

- **On demand in CI** (recommended): dispatch `.github/workflows/pipeline-eval.yml`
  from the Actions tab. It fetches the corpora, runs the matrix on the same
  macOS runner the regular `iOS CI` workflow uses, and publishes a report as a
  job summary + artifact. Nobody needs Xcode locally for this.
- **Locally**, if you have a Mac: run `fetch_all.py` below, then
  `KURN_PUBLIC_EVAL_DATA=... xcodebuild ... test -only-testing:KurnTests/PublicDatasetEvaluationHarnessTests`.

## Why the corpus still isn't committed

Unlike `Tools/evaluation/`'s private corpus, there's no privacy reason a
public dataset couldn't sit in the repository. It stays out anyway: even a
handful of clips per language is tens of megabytes, a full matrix run needs
GGML/CoreML model files that are hundreds of megabytes more, and neither
belongs in git history. Fetching on demand also means `manifest.json` can be
edited (swap a dataset, change the sample count) without a code review of
binary blobs.

## What's fetched, and why these four

| Corpus | Language | Gives | Why |
| --- | --- | --- | --- |
| LibriSpeech test-clean | English | WER | Clean, single-speaker, the standard ASR sanity check. Ungated, no token needed. |
| AMI Meeting Corpus (Mix-Headset) | English | DER only | Real multi-speaker meeting audio -- the only corpus here whose overlap and crosstalk look like what the app actually records. Its lexical transcript is locked in AMI's NXT XML, which this tooling deliberately does not parse (see `fetch_ami.py`'s docstring), so it contributes diarization-only material. |
| Common Voice 17.0 (pt) | Portuguese | WER | Gated (needs `HF_TOKEN`, see below) but broad accent/speaker coverage. |
| CORAA v1.1 (pt) | Portuguese | WER | `Racoci/CORAA-v1.1` (`default` config, `test` split) in Parquet format. Brazilian Portuguese spontaneous speech across five source projects. License is `CC BY-NC-ND 4.0`. |

**There is no Portuguese diarization corpus here.** A public, freely
downloadable multi-speaker Portuguese corpus with turn-level annotation
comparable to AMI was not identified. DER for Portuguese stays a known gap in
this measurement, same honesty as `Tools/evaluation/README.md`'s own
"comparable between runs, not against published figures" caveat -- better to
say so than to fake it with a mismatched or synthetic substitute.

## Setup

```bash
python3 -m pip install -r requirements.txt   # datasets, huggingface_hub
brew install ffmpeg                          # only needed for the AMI fetch
```

## Fetching

```bash
python3 fetch_all.py --out ~/kurn-eval-public
```

Fetches every corpus with `"enabled": true` in `manifest.json`. Add
`--only librispeech-en ami-en` to fetch a subset while iterating.

### Gated datasets (Common Voice, and CORAA once enabled)

Hugging Face gates Common Voice behind an account that has clicked "agree" on
the dataset's page once. After doing that:

```bash
export HF_TOKEN=hf_...   # a read-scoped token from huggingface.co/settings/tokens
python3 fetch_all.py --out ~/kurn-eval-public
```

In CI, this is the `HF_TOKEN` repository secret referenced by
`.github/workflows/pipeline-eval.yml`. Without it, gated corpora are skipped
with a clear message rather than silently producing an empty directory.

## Running the harness

```bash
KURN_PUBLIC_EVAL_DATA=~/kurn-eval-public \
KURN_PUBLIC_EVAL_REPORT=~/kurn-eval-public/report.csv \
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:KurnTests/PublicDatasetEvaluationHarnessTests
```

`KURN_PUBLIC_EVAL_MATRIX=essential` restricts the run to the 4-entry cleanup
on/off x diarization heuristic/FluidAudio sweep (holding VAD and ASR engine at
their zero-download defaults) instead of the full 24-entry matrix -- useful
for a fast local check. Omit it, or set it to anything else, to run the full
matrix.

### Including cloud Whisper (OpenAI, Groq)

Every engine above is on-device and free to run unattended. `.whisperAPI` is
opt-in and additive on top of the base matrix: set `OPENAI_API_KEY` and/or
`GROQ_API_KEY` in the environment the test process runs in, and the harness
adds 8 more configurations per provider (preprocessing x VAD x diarization,
against that provider's Whisper endpoint) -- the key never has to be pasted
into Settings by hand, since the harness seeds it into the same Keychain
account `ProviderFactory` reads. Costs real API usage per call; keep
`sample_count` in `manifest.json` small if you enable this.

In CI, wire `secrets.OPENAI_API_KEY` / `secrets.GROQ_API_KEY` into the
`pipeline-eval` workflow's env only if you want those entries in the matrix --
they're absent by default, so the workflow costs nothing to third parties
until a maintainer opts in.

Output is on `[pipeline-eval]` lines, same convention as the private harness's
`[eval]` lines -- per-item WER/DER, then a `=== aggregate ===` table of
corpus-level WER/DER per (language, configuration), which is the table to
actually compare between runs. `KURN_PUBLIC_EVAL_REPORT` additionally writes
every (item, configuration) row as CSV, for pulling into a spreadsheet or
diffing between two runs.

There is deliberately no pass/fail threshold, for the same reason
`Tools/evaluation/README.md`'s harness has none.
