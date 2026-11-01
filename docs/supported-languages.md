# Supported Languages

Kurn has two independent notions of "language," and they are configured in
different places:

- **UI languages** — the language the app's own interface (buttons, menus,
  Settings, error messages) is displayed in. Chosen automatically from the
  device's system language.
- **Transcription languages** — the language a meeting is transcribed in.
  Chosen per-meeting or as a default in Settings, independent of the UI
  language (you can run a fully English UI while transcribing a meeting in
  Swahili, for example).

This file lists both, and explains how to contribute a new UI language.

## UI languages

Kurn's interface is currently localized into 7 languages:

| Language | Locale | `.lproj` folder |
| --- | --- | --- |
| English (base/reference) | `en` | `Kurn/Resources/en.lproj` |
| Portuguese (Brazil) | `pt-BR` | `Kurn/Resources/pt-BR.lproj` |
| Spanish | `es` | `Kurn/Resources/es.lproj` |
| French | `fr` | `Kurn/Resources/fr.lproj` |
| German | `de` | `Kurn/Resources/de.lproj` |
| Italian | `it` | `Kurn/Resources/it.lproj` |
| Chinese (Simplified) | `zh-Hans` | `Kurn/Resources/zh-Hans.lproj` |

Each locale has its own `Localizable.strings` file with the same keys as the
English (base) file — `en.lproj/Localizable.strings` is the reference every
other locale must stay in sync with. The Watch app (`KurnWatch/`) and the
Live Activity widget (`KurnLiveActivityExtension/`) each ship their own,
smaller `Localizable.strings` pair and currently only support English and
Brazilian Portuguese.

## Transcription languages

`MeetingLanguage` (`Kurn/Models/MeetingLanguage.swift`) covers every language
OpenAI's Whisper model supports, plus auto-detect — 101 options in total.
This list is independent of the UI languages above; it's available for
transcription regardless of which UI language is active.

Support depends on the selected engine **and model family**, not just the
language picker. All FluidAudio choices below run on device after an explicit
model download.

| Engine / model family | Explicit transcription languages | Auto-detect |
| --- | --- | --- |
| Whisper API (cloud) / Whisper via whisper.cpp (on device) | Full list below | Yes |
| Apple on-device Speech | Locales available through `SFSpeechRecognizer` on the current device/iOS version; checked at runtime | Not a multilingual Auto mode |
| FluidAudio Parakeet TDT v3 (default FluidAudio ASR model) | 25 European languages listed below | Yes |
| FluidAudio Nemotron Unified 0.6B | Same 25 European languages, including generic Portuguese (`pt`) | Yes; no detected-language code is reported by this integration |
| FluidAudio Bark 3.0 / Bark 3.0 Clean | **English only**, explicitly selected | **No** |
| FluidAudio Phonon-2 | **English only**, explicitly selected | **No** |
| FluidAudio Nemotron 3.5 Transcribe Lite | **English only**, explicitly selected | **No** |

The 25-language FluidAudio set is Bulgarian (`bg`), Croatian (`hr`), Czech
(`cs`), Danish (`da`), Dutch (`nl`), English (`en`), Estonian (`et`), Finnish
(`fi`), French (`fr`), German (`de`), Greek (`el`), Hungarian (`hu`), Italian
(`it`), Latvian (`lv`), Lithuanian (`lt`), Maltese (`mt`), Polish (`pl`),
Portuguese (`pt`), Romanian (`ro`), Russian (`ru`), Slovak (`sk`), Slovenian
(`sl`), Spanish (`es`), Swedish (`sv`), and Ukrainian (`uk`).

**Portuguese is a transcription language, not a UI locale or a quality claim.**
The Portuguese picker entry is generic `pt`; the Brazilian Portuguese UI locale
(`pt-BR`) does not select a Brazilian-specific ASR model. Parakeet v3 and
Nemotron Unified accept `pt` and Auto, but Unified's language coverage does not
establish Brazilian Portuguese accuracy. In Auto, Unified does not populate a
detected-language code. Bark, Bark Clean, Phonon-2, and Transcribe Lite do not
support Portuguese. They require the meeting language to be **English**;
Auto is unsupported even if the recording happens to be in English.
The existing Parakeet measurements in [pipeline evaluation](pipeline-evaluation.md)
are not evidence of accuracy for the additional models.

Live preview has an independent model choice and download:

| Live-preview choice | Explicit languages | Auto-detect |
| --- | --- | --- |
| Automatic Parakeet EOU / Nemotron Multilingual (default) | English (`en`, EOU); Chinese (`zh`), French (`fr`), German (`de`), Italian (`it`), Japanese (`ja`), Portuguese (`pt`), Spanish (`es`) through the multilingual model | Yes, through the multilingual model |
| Nemotron Unified 0.6B | The same 25 European languages as Unified batch ASR | Yes |

Unified live uses an fp16 streaming encoder distinct from its batch encoder;
installing one does not install the other. They share a Storage folder, so
deleting it removes both. Live output is a temporary preview, not the saved
transcript or a detected-language result. Selecting a batch ASR model does not
change live preview or the optional language detector: FluidAudio language
detection still uses Parakeet v3 under its own consented setting.

Language pickers warn about unsupported selections, Settings disables incompatible
model choices, and the pipeline validates again before running (see
`Kurn/Services/TranscriptionLanguageSupport.swift`). Auto is not a bypass for an
English-only model. The additional models' real-audio accuracy, speed, and
physical-device inference/memory behavior still need validation. These choices
cover transcription and diarization only, not TTS, Canary translation, or voice
cloning.

### Full transcription-language picker

| Language | Whisper code |
| --- | --- |
| Auto-detect | — |
| Afrikaans | af |
| Albanian | sq |
| Amharic | am |
| Arabic | ar |
| Armenian | hy |
| Assamese | as |
| Azerbaijani | az |
| Bashkir | ba |
| Basque | eu |
| Belarusian | be |
| Bengali | bn |
| Bosnian | bs |
| Breton | br |
| Bulgarian | bg |
| Burmese | my |
| Cantonese | yue |
| Catalan | ca |
| Chinese | zh |
| Croatian | hr |
| Czech | cs |
| Danish | da |
| Dutch | nl |
| English | en |
| Estonian | et |
| Faroese | fo |
| Finnish | fi |
| French | fr |
| Galician | gl |
| Georgian | ka |
| German | de |
| Greek | el |
| Gujarati | gu |
| Haitian Creole | ht |
| Hausa | ha |
| Hawaiian | haw |
| Hebrew | he |
| Hindi | hi |
| Hungarian | hu |
| Icelandic | is |
| Indonesian | id |
| Italian | it |
| Japanese | ja |
| Javanese | jw |
| Kannada | kn |
| Kazakh | kk |
| Khmer | km |
| Korean | ko |
| Lao | lo |
| Latin | la |
| Latvian | lv |
| Lingala | ln |
| Lithuanian | lt |
| Luxembourgish | lb |
| Macedonian | mk |
| Malagasy | mg |
| Malay | ms |
| Malayalam | ml |
| Maltese | mt |
| Maori | mi |
| Marathi | mr |
| Mongolian | mn |
| Nepali | ne |
| Norwegian | no |
| Norwegian Nynorsk | nn |
| Occitan | oc |
| Pashto | ps |
| Persian | fa |
| Polish | pl |
| Portuguese | pt |
| Punjabi | pa |
| Romanian | ro |
| Russian | ru |
| Sanskrit | sa |
| Serbian | sr |
| Shona | sn |
| Sindhi | sd |
| Sinhala | si |
| Slovak | sk |
| Slovenian | sl |
| Somali | so |
| Spanish | es |
| Sundanese | su |
| Swahili | sw |
| Swedish | sv |
| Tagalog | tl |
| Tajik | tg |
| Tamil | ta |
| Tatar | tt |
| Telugu | te |
| Thai | th |
| Tibetan | bo |
| Turkish | tr |
| Turkmen | tk |
| Ukrainian | uk |
| Urdu | ur |
| Uzbek | uz |
| Vietnamese | vi |
| Welsh | cy |
| Yiddish | yi |
| Yoruba | yo |

Adding a transcription language means adding a Whisper-supported language
that isn't in this list yet, which is rare (the list above already covers
every language Whisper's model recognizes). Adding a **UI** language is far
more common — see below.

## Contributing a new UI language

No need to open an issue first for a translation — a PR is enough.

1. **Pick the locale code.** Use the BCP-47 identifier Apple/Xcode expects
   for the language (e.g. `ja` for Japanese, `ko` for Korean, `zh-Hant` for
   Traditional Chinese). If in doubt, check what identifier
   `Locale(identifier:)` / Xcode's own localization list uses for that
   language.

2. **Create the `.lproj` folder.** Copy
   `Kurn/Resources/en.lproj/Localizable.strings` (the English file is the
   reference — always translate from it, not from another translation) into
   a new `Kurn/Resources/<locale>.lproj/Localizable.strings`.

   The project uses Xcode 16 file-system-synchronized groups, so simply
   adding the folder and file under `Kurn/Resources/` is enough for Xcode to
   pick it up as a resource — no manual project file surgery needed for the
   file itself.

3. **Translate every value**, not the keys:
   - Never rename, add, remove, merge, or reorder a `"key" = "value";` line.
     Only translate the string on the right-hand side of `=`.
   - Preserve every placeholder token exactly as it appears — `%@`, `%d`,
     `%1$@`, `%2$@`, `%1$d`, etc. You may reorder `%1$@`/`%2$@` if your
     language's grammar needs a different word order, but never drop, add,
     or change a placeholder itself.
   - Translate the `/* Section comment */` header lines too, mirroring how
     `pt-BR.lproj/Localizable.strings` does it.
   - Keep translations **short**. Many strings are button labels, Picker
     rows, and Settings rows on a phone screen — a translation 2-3x longer
     than the English source can visually break the UI. Prefer a shorter,
     natural phrasing over a long literal translation.
   - The `lang.*` keys (~101 of them) are the display names shown in the
     transcription-language pickers described above — translate each into a
     1-2 word name for that language, not a longer description.
   - `status.in_progress` intentionally appears twice in the source file
     with different English values for two different contexts — keep both
     occurrences, each translated for its own context.

4. **Register the locale in Xcode.** Add the locale code to `knownRegions`
   in `Kurn.xcodeproj/project.pbxproj` (find the `PBXProject` section), so
   Xcode and App Store Connect recognize it as a supported localization.

5. **Verify key parity** before opening a PR — every key in the English file
   must exist in your new file, and no key should be missing, extra, or
   duplicated differently than the source. A quick way to check:

   ```bash
   diff \
     <(grep -oE '^"[^"]+"' Kurn/Resources/en.lproj/Localizable.strings | sort) \
     <(grep -oE '^"[^"]+"' Kurn/Resources/<locale>.lproj/Localizable.strings | sort)
   ```

   An empty diff means the key sets match.

6. **Build, lint, and test** as described in
   [CONTRIBUTING.md](../CONTRIBUTING.md#build-lint-and-test-commands), then
   open a PR. Mention the new language in the PR description.

Extending the Watch app or Live Activity widget's smaller `Localizable.strings`
pairs to a new language is optional and out of scope for a UI-language PR
unless you want to do it.
