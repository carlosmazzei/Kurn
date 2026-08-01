# Measuring accuracy on your own recordings

Every accuracy claim about this app's pipeline — "Whisper's own thresholds",
"the standard far-field front end", "reduces DER by 3–7 points" — is inference
from the literature, not measurement on this material. `KurnTests/Support/Evaluation/`
implements the two standard metrics so that can change. This is the recipe for
feeding them.

It is a **manual, occasional step**, like `Tools/gtcrn/`. Nothing here runs in
CI: the harness is skipped unless `KURN_EVAL_DATA` is set, which is how CI runs,
because the corpus **cannot be committed**. Meeting recordings are the most
private thing this app touches — the reason every byte of them is encrypted at
rest — so a folder of real ones with transcripts is exactly what must never
reach the repository. Keep it outside, and keep it out of any backup you would
not trust with the meetings themselves.

## What you need per recording

Named by a shared base name, all in one flat directory:

| File | For | How you get it |
| --- | --- | --- |
| `<name>.reference.txt` | WER | you type/correct what was actually said |
| `<name>.hypothesis.txt` | WER | the app's Markdown export, via `prepare.py transcript` |
| `<name>.reference.rttm` | DER | you annotate who spoke when, via `prepare.py labels` |
| `<name>.m4a` | DER | the recording itself, off the device |

You can do WER only, DER only, or both. One real ten-minute meeting is already
worth more than any amount of reasoning about this pipeline.

> **For DER, supply the audio — not a hand-written `<name>.hypothesis.rttm`.**
> The harness accepts one, but with the `.m4a` present it runs the app's own
> diarizer and scores that, which is the only variant that catches a regression:
> it re-derives the result on every run. The Markdown export cannot substitute,
> because it records each segment's *start* and not its end, so an RTTM
> reconstructed from it would be approximate in a way that contaminates the
> measurement rather than showing up as an error.

## 1. Get the recording off the device

The app deliberately does **not** declare `UIFileSharingEnabled`, so recordings
do not appear in the Files app or in Finder — and that should stay true; opening
a meeting archive to the Files app for the convenience of testing is a privacy
change nobody asked for.

- **Device:** Xcode → Window → Devices and Simulators → select the device →
  select Kurn under Installed Apps → the gear menu → **Download Container…**.
  Right-click the resulting `.xcappdata` → Show Package Contents; the recordings
  are in `AppData/Documents/Recordings/`.
- **Simulator:** the container is on disk already —
  `xcrun simctl get_app_container booted ai.kurn.app data`, then
  `Documents/Recordings/`.

File names are `<meetingID>_<timestamp>.m4a`. Rename to something you can type.

## 2. Get the app's transcript out

In the app: open the meeting → share → export. That produces Markdown containing
a `## Transcript` section with one line per segment
(`**[mm:ss] Speaker:** text`). Save it, then:

```bash
python3 prepare.py transcript ~/Downloads/weekly.md --out ~/kurn-eval/weekly.hypothesis.txt
```

The script strips the timestamps and speaker names and keeps only the words —
WER compares what was said, and leaving the labels in would count them as spoken
words and inflate the denominator with text nobody uttered.

Then write `weekly.reference.txt` by listening and correcting. Punctuation and
capitalization do not matter (`TextNormalizer` folds them); the words do.

## 3. Annotate who spoke when

[Audacity](https://www.audacityteam.org) is the shortest path, and free:

1. Open the `.m4a`.
2. Select a speaker's turn → **Tracks → Add Label at Selection** (⌘B), and type
   the speaker's name as the label text. One label per turn.
3. **File → Export → Export Labels…**, which writes
   `start<TAB>end<TAB>label`.

```bash
python3 prepare.py labels ~/Downloads/weekly-labels.txt --out ~/kurn-eval/weekly.reference.rttm
```

Two rules the script enforces rather than silently working around: a speaker
name **cannot contain a space** (RTTM is space-separated, so `Ana Souza` would
be read back truncated), and a label cannot end before it starts.

Annotate the boundaries roughly — the scorer applies a ±0.25 s collar around
every reference boundary precisely because neither you nor a diarizer can place
the instant a word ended. **Do** annotate overlapping speech as overlapping
labels if it happens; that is what quantifies the app's biggest known gap.

## 4. Run it

```bash
KURN_EVAL_DATA=~/kurn-eval xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:KurnTests/EvaluationHarnessTests
```

Output is on `[eval]` lines:

```
[eval] weekly: WER 14.2% (S 31, I 4, D 12 over 331)
[eval] WER over 1 file(s): 14.20%
[eval] weekly (heuristic): DER 38.9% (missed 12.4s, false alarm 3.1s, confusion 91.0s of 273.5s)
[eval] weekly: reference speakers 3, found 1
[eval] weekly: mapping [("Ana", "Speaker 1")]
```

## Reading the result

**The breakdown matters more than the rate.** They have different fixes:

| Signal | Means | Where to look |
| --- | --- | --- |
| WER **deletions** | speech the pipeline dropped | VAD gating, `TranscriptQualityFilter` rejecting real segments, a chunk boundary |
| WER **insertions** | speech it invented | hallucination — the filter is not catching it |
| WER **substitutions** | mishearing | the model, the language setting, the audio itself |
| DER **confusion** | right speech, wrong person | clustering — the app's known collapse |
| DER **missed** | speech heard as silence | the diarizer's own VAD, or overlapping speech a single-label result cannot represent |
| DER **false alarm** | silence heard as speech | noise mistaken for a turn |

The `mapping` line is what explains a bad DER: the score is taken under the
speaker assignment that *maximises* agreement, because a diarizer's labels are
arbitrary. `reference speakers 3, found 1` with all the error in confusion is
the collapse, not a boundary problem.

**What these numbers are not.** They are comparable **between runs over the same
material** — which is what makes them useful for "did this change help?" — and
not against published figures for the same audio. The normalization here is
deliberately language-neutral (no number expansion, no contraction splitting, no
filler-word list, all of which are per-language and none of which are done), and
for Chinese and Japanese the rate is a *character* error rate because those are
written without spaces.

There is deliberately **no pass/fail threshold**. A budget invented in this
repository would have no provenance, and the first time it failed the temptation
would be to raise it. Record the number, change something, run it again.
