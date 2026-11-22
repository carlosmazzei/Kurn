# Design prototypes

The interface the app follows is specified by a navigable HTML prototype, one
file per revision. It is the source the decisions in `CLAUDE.md` → "Visual
system" and `docs/roadmap.md` → "Design review implementation" refer to; when a
screen and the prototype disagree, the table below says which deviations are
intentional. Anything else is a bug.

| Revision | File | Implemented on | Notes |
| --- | --- | --- | --- |
| 10 (2026-11-21) | `kurn-interface-review-r10.html` | `feature/ui-design-review` (PR #465) | Includes the later "Descartar" addition to the recorder (separate glass capsule, red label, confirmation). |

## How to use it

Open the file in a browser (`open docs/design/kurn-interface-review-r10.html`).
It has four views: **Protótipo** (every screen, sheet, menu and dialog, light
and dark, with the interactions listed beside the phone — tap the phone to
follow them), **Fluxos** (eleven end-to-end flows), **Mapa de telas** (which
`Views/*.swift` file each screen maps to) and **Sistema visual** (colours,
typography, components, glyphs, names, accessibility rules). Each screen is
tagged *novo* / *muda* / *igual* against the app before the review.

The published copy has the "Hoje" screenshots (captures of the pre-review app)
removed to keep the file small; the "before" state is the base commit of the
review branch (`5cdd2cf9` on `feature/knowledge-compiler`), and the per-screen
captures taken during implementation live in the PR.

## Intentional deviations from revision 10

| Where | Prototype | App | Why |
| --- | --- | --- | --- |
| Recorder | No title field; a provisional "Reunião de 19:30" title the AI replaces later | Keeps the editable title field (empty, with the provisional title as placeholder) | User decision: typing a title while recording stays possible. |
| Recorder | "Parar só para e salva", no Discard in the first draft | Discard kept, in its own capsule with a confirmation dialog | User decision; the prototype was then updated to show it this way. |
| Wiki naming | "Wiki" everywhere | "Wiki" in every visible string; code identifiers, type names, accessibility identifiers and localization keys keep `knowledge` | Renaming code would churn tests, static policy and the K-track docs for no user benefit. |
| Filters → Período | "Escolher…" (custom date range) | Not offered yet | `MeetingDateFilter` is a string-backed enum persisted in smart folders; a range needs a model change. Deferred in the roadmap. |
| Watch | "Gravar" complication on the watch face | Not built | Needs a watchOS widget target. Deferred. |
| Audio → recording menu | "Renomear" | Not offered | `Recording` has no user-visible name. Deferred. |
| Settings hub | Search, Usage, Health, Diagnostics as separate rows | Same as the prototype | Listed because the roadmap's U1.4 wanted them merged; the prototype's choice won. |
| List indicators | Grey `#a5a5aa` | `Theme.indicator` = `textTertiary` (darker grey) | The prototype's grey fails the 3:1 contrast floor for glyphs. |
| Transcript speaker name | Dark tone of the speaker colour | Primary label colour; the colour is on the avatar only | Speaker colours are not all 4.5:1 on paper. |
| Summary tab | Swipe left/right over the text switches summaries | Page dots are tappable; the pill menu lists them | A drag gesture on the summary body competed with the ScrollView and blocked vertical scrolling. |
| Mentioned in (wiki page) | Row opens the meeting | Row is informational (count only) | The Wiki reader is a sheet and cannot push the meeting detail safely. |

## Adding a revision

1. Export the new HTML next to the previous one (`kurn-interface-review-rNN.html`),
   stripping embedded screenshots of the current app the same way (search for
   `const TODAY=`).
2. Add a row to the first table and update the deviations table.
3. Record the decisions it changes in `CLAUDE.md` → "Visual system" and the
   status in `docs/roadmap.md` before implementing.
