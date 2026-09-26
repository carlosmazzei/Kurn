# Design review: Liquid Glass / HIG adherence (2026-09-26)

This is the single source of truth for the design-consistency remediation
track opened by the 2026-09-26 HIG/Liquid Glass review: what was found, why it
matters, and the tracked plan (D1–D8) to fix it. Status per track is kept
current here rather than in a PR description, the same convention
`docs/resilience.md` uses for the H1–H10 hardening track.

**Methodology.** The review was performed by reading the SwiftUI source under
`Kurn/Views/` (not rendered screenshots), cross-referenced against the current
Apple Human Interface Guidelines, including Liquid Glass as introduced in
iOS/iPadOS 26 and macOS Tahoe 26. That gives high confidence in structural
findings — which presentation API is used where, whether a button style or
accessibility label is present, whether a pattern repeats consistently across
screens — and low confidence in anything that only shows up in a render (exact
contrast ratios, fine-grained spacing, legibility at large Dynamic Type sizes).
Findings of the second kind are marked "not verifiable without a render" and
should be re-checked visually before being marked done.

Three axes were reviewed transversally, per the original request, because they
are where per-screen review misses the real problem: **modal consistency**
(does the same kind of situation get the same presentation everywhere),
**objective visual clarity** (does a screen communicate its purpose and
primary action without competing elements), and **simplicity** (does any
screen ask for more attention or steps than the task needs).

**Overall adherence at time of review: 6.5/10.** The app already completed the
structural migration to native Liquid Glass toolbars in `MeetingsListToolbar`
and `MeetingDetailToolbar`, has real accessibility discipline (labels,
`Theme`'s semantic typography, 7-locale parity), and a clean, consistent
convention for destructive actions (`Button(role: .destructive)`). The problem
is not absence of a pattern — it is that **3–4 different patterns coexist for
the same kind of situation** (confirmation dialogs, primary-button styling,
empty states), which is exactly what the modal-consistency and clarity axes
were meant to catch.

**This score is a pre-implementation snapshot.** All eight tracks have since
been implemented; re-scoring after a render-based visual pass (especially for
D6's iPad `NavigationSplitView`) would be the natural next step, but is out
of scope for a Linux session with no Xcode/simulator.

## Corrections found during implementation

Two findings from the original code-only review turned out to be wrong once
implementation cross-checked them against files the review's Explore pass
didn't read in full (`Theme.swift`, `View+ErrorAlert.swift`, and the UI test
suite). Both are corrected here rather than silently fixed, since the original
severity ratings and the D2 track description above were written on the wrong
premise.

- **F1 was a false positive.** `Theme.accent` is not a neutral brand color —
  it's defined as `Color(hex: "#FF3B30")`, which *is* system red. `kurnDialog`
  already renders its destructive button in `Theme.accent` (red) and its
  normal primary button in `Theme.info` (blue): the destructive/non-destructive
  color distinction was correct all along. No code change was needed for F1;
  it is closed as verified-correct rather than fixed.
- **F2's direction was backwards.** The review read "3 competing confirmation
  mechanisms" as the custom `kurnDialog` being 25 outliers against 1 native
  `.alert`. In fact the app's shared `errorAlert(_:)` view modifier — used
  across most of `Views/` for surfacing `AppError` — itself wraps `kurnDialog`,
  making `kurnDialog` the deliberate, established convention, not a deviation
  from it. The lone native `.alert` in `ModelStoreBootViews.swift` was the
  actual outlier and has been migrated to `kurnDialog` for consistency (see D2
  below) — the reverse of the original recommendation to migrate `kurnDialog`
  to native `.alert`.
- **Migrating `kurnDialog` wholesale would have broken CI.**
  `KurnUITests/Flows/LibraryFlowUITests.swift` and `SettingsFlowUITests.swift`
  drive `kurnDialog` directly through its `dialog.title`/`dialog.primary`/
  `dialog.secondary` accessibility identifiers (also documented in this
  project's CLAUDE.md, "Accessibility" section). A native SwiftUI `.alert`
  does not expose equivalent stable per-button identifiers, so replacing the
  ~25 `kurnDialog` call sites with native alerts, as the original F2
  recommended, would have broken these required `ui-accessibility-tests`. D2 is
  rescoped accordingly: **keep `kurnDialog`** as the app's confirmation/alert
  component; only the single native-`.alert` outlier moves.

## Findings register

Each finding below is tagged with the track (D1–D8) that will fix it. Severity
follows the original review: Crítico / Alto / Médio / Baixo.

| ID | Finding | File(s) | Severity | Track |
|----|---------|---------|----------|-------|
| F1 | ~~`kurnDialog`'s destructive button uses `Theme.accent`, not a semantic red~~ — **false positive, see "Corrections" above**: `Theme.accent` already *is* system red (`#FF3B30`); destructive/normal roles were already colored correctly | `DesignComponents.swift:298` | ~~Crítico~~ Closed, no change needed | D2 |
| F2 | ~~Three competing confirmation mechanisms~~ — **direction corrected, see "Corrections" above**: `kurnDialog` is the app's deliberate, established convention (the shared `errorAlert` modifier wraps it), and is required as-is by `LibraryFlowUITests`/`SettingsFlowUITests`. The actual outlier was the single native `.alert` in `ModelStoreBootViews.swift`, migrated to `kurnDialog` instead. | `ModelStoreBootViews.swift:105` (fixed); `DesignComponents.swift:230-316` (kept, confirmed correct) | Médio (was Alto, rescoped) | D2 |
| F3 | ✅ Fixed — only 3 of ~38 sheets used `.presentationDetents`; short utility pickers (mic choice, summary template, translate language, tag picker) opened full-height by default. Added `.presentationDetents` (`[.medium]` for the fixed-length language picker, `[.medium, .large]` for the growable template/tag/auto-tag pickers). | `SummaryTemplatePicker.swift`, `SummaryTranslateLanguagePicker.swift`, `TagPickerView.swift`, `AutoTagConfirmView.swift` | Médio | D1 |
| F4 | ✅ Fixed — `RecorderView`'s exit button always read "Cancel" even though `cancel()` deletes the in-progress recording once one exists. Now shows a destructive-styled "Discard Recording" once `state != .idle`, and a plain "Cancel" beforehand. | `RecorderView.swift:110-124`; new key `recorder.discard` added to all 7 locales | Médio | D2 |
| F5 | ✅ Resolved — read the picker views' bodies; all four (mic choice via `.confirmationDialog`, template picker, translate-language picker, tag picker, auto-tag confirm) already have an explicit Cancel/Done toolbar action. No further change needed. | — | Baixo | D2 |
| F6 | ✅ Fixed — `ContentView` now branches on `.horizontalSizeClass`: `NavigationSplitView` with `FolderSidebarView` as a persistent sidebar column on regular width, the original `NavigationStack`/sheet on compact. | `ContentView.swift`, `MeetingsListView.swift`, `MeetingsListToolbar.swift` | Crítico (estrutural) → fixed | D6 |
| F7 | ✅ Fixed — replaced with `.safeAreaBar(edge: .bottom)`, the same Liquid-Glass-native pattern already used by `MeetingShareSelectionView`, so the progress strip gets the system glass material instead of a hand-set `.bar` background. | `DocumentCreateView.swift:137-152` | Médio | D1 |
| F8 | ✅ Fixed — `.buttonStyle(.borderedProminent)` → `.buttonStyle(.glassProminent)`, matching `RecorderView`'s Stop button in the same journey. | `MeetingDetailView.swift:520` | Alto | D1 |
| F9 | ✅ Addressed by decision, not mass-migration — `Theme.swift`'s new "Button language" table makes `.plain` the *correct*, documented choice for list/menu rows and chips, which is what most of the ~45 sites are. The two sites that were actually a screen's primary CTA in disguise (a hand-drawn colored rectangle) were migrated to `.glassProminent`. | `MeetingsListComponents.swift` (Unlock button), `ModelStoreBootViews.swift` (Retry button) fixed; `DesignComponents.swift:139,314` etc. confirmed correct as `.plain` | Médio → mostly non-issue once documented | D4 |
| F10 | ✅ Addressed — the button-language decision table now names exactly one style per situation (`Theme.swift`); the `.borderedProminent` outlier (F8) is fixed, and `kurnDialog`'s buttons are confirmed correct rather than a fourth competing language (see F1/F2 corrections). | `Theme.swift` "Button language" section | Alto → resolved | D4 |
| F11 | ✅ Fixed — all ~35 call sites either moved to a `Theme` semantic font or a scalable `.system(.textStyle, weight:)` call (matching `Theme.swift`'s own construction), or were left as a documented fixed-geometry exception (icon inside a small fixed circle/grid cell, e.g. `RecorderView`'s transport buttons, folder icon/color pickers, chat composer send/stop buttons) with an inline comment explaining why. | ~35 sites across `Views/` (see D3 implementation notes) | Alto → fixed | D3 |
| F12 | ✅ Verified — `SummaryView.swift:80`'s size-6 `circle.fill` is a decorative bullet marker (`.accessibilityHidden(true)`), not text. No change needed. | `SummaryView.swift:80` | Médio → closed, verified decorative | D3 |
| F13 | ✅ Verified, no change needed — the scrim dims the background behind the dialog card the same way the system's own sheet/alert dimming does; WCAG contrast criteria apply to text/UI-component contrast, not a background-dimming layer. | `DesignComponents.swift:193` | Médio → closed, verified correct | D5 |
| F14 | ✅ Confirmed via WCAG computation and fixed — white on `Theme.accent`/`Theme.info` measures ~3.55:1/~3.65:1, below the 4.5:1 AA floor for normal text. Fixed by using bold `.subheadline` (≥14pt bold "large text", 3:1 floor) for the button label instead of `Theme.footnoteEmphasized`. | `DesignComponents.swift:298-305` | Médio → confirmed real, fixed | D5 |
| F15 | ✅ Verified via WCAG computation — worst-case background luminance (gradient center, `.recording` state) yields ~19:1 contrast for white text, far above AAA. The documented exception is confirmed safe. | `RecorderView.swift:77,121,208,211,222,241,279,381` | Baixo → verified safe | D5 |
| F16 | ✅ Fixed, narrower than first proposed — the elapsed time and highlight count (`timer`) were the actual two-separate-nodes problem (`statusBadge`'s icon is already `.accessibilityHidden`, so it was already a single node); combining `statusBadge` into the same element would have required reordering `startingIndicator` out from between them, a layout change out of scope for an accessibility fix. `timer` now combines into one composed label ("12:34, 2 highlights") only when there's a count to report; visual layout is unchanged. | `RecorderView.swift` `timer` | Médio → fixed | D7 |
| F17 | ✅ Fixed — explicit `.accessibilityLabel` added to the title `TextField`, independent of the placeholder. | `RecorderView.swift:243-260` | Médio → fixed | D7 |
| F18 | ✅ Fixed — the two hand-rolled `VStack` empty states were migrated to `ContentUnavailableView`, matching the pattern already used in Documents. | `MeetingsListView.swift`, `ChatSessionListView.swift` (fixed); `DocumentsListView.swift:28`, `DocumentCreateView.swift:212` (already correct) | Médio → fixed | D8 |

Findings confirmed as **already correct** (no action needed, kept here as a
baseline so a future change doesn't regress them): consistent `role:
.destructive` usage across swipe actions and menus; the Share sheet's uniform
`.sheet(item:)` + `UIActivityViewController` pattern across 8 call sites; the
Liquid-Glass toolbar pattern in `MeetingsListToolbar`/`MeetingDetailToolbar`;
`RecorderView`'s highlight button (icon-only, `.frame(58×58)`,
`.accessibilityLabel` present); decorative elements (pulsing dot, waveform)
correctly marked `.accessibilityHidden(true)`; color literals sourced from the
curated `FolderColorPalette`/`TagColorPalette` via `Color(hex:)`.

## Remediation plan

Tracks are ordered by the priority matrix below, not by ID. Each track lists
scope, acceptance criteria, and status. Mark a track's status inline as work
lands; do not open a second document to track this.

### D1 — Low-effort / high-impact fixes (quick wins)
**Status: Done**

- ✅ F8: `MeetingDetailView.swift:520` changed from `.buttonStyle(.borderedProminent)` to `.buttonStyle(.glassProminent)`, matching `RecorderView`'s Stop button.
- ✅ F3: added `.presentationDetents` to the short utility pickers: `[.medium]` on `SummaryTranslateLanguagePicker` (fixed 7-language list), `[.medium, .large]` on `SummaryTemplatePicker`, `TagPickerView` and `AutoTagConfirmView` (lists that can grow with user-created content).
- ✅ F7: `DocumentCreateView.swift`'s `.safeAreaInset(edge: .bottom) { ... .background(.bar) }` replaced with `.safeAreaBar(edge: .bottom) { ... }`, the same Liquid-Glass pattern `MeetingShareSelectionView` already uses, so the generation-progress strip gets the system glass material automatically instead of a hand-set one.

**Acceptance met:** no more `.borderedProminent` in the codebase; the four named pickers open at `.medium`/`[.medium, .large]` height; zero remaining `.background(.bar)` outside intentional system chrome.

### D2 — Unify confirmation/alert mechanisms
**Status: Done — rescoped, see "Corrections found during implementation" above**

- F1 required no change: verified `kurnDialog` already colors destructive vs. normal primary buttons correctly (`Theme.accent` red vs. `Theme.info` blue).
- F2 rescoped: rather than migrating `kurnDialog` to native `.alert`, ✅ migrated the app's one native-`.alert` outlier (`ModelStoreBootViews.swift:105`, a single-OK-button error dialog) to `kurnDialog`, matching the convention the shared `errorAlert(_:)` modifier already establishes elsewhere. `kurnDialog` itself is kept as-is.
- ✅ F4: `RecorderView`'s exit `ToolbarItem` now reads "Discard Recording" with `role: .destructive` once `vm.state != .idle || vm.isStarting` (the same condition already gating `.interactiveDismissDisabled`), and plain "Cancel" with `role: .cancel` beforehand — the label and role now match the real consequence of `RecorderViewModel.cancel()`, which deletes the in-progress recording. New localization key `recorder.discard` added to all 7 locales.
- ✅ F5: confirmed all picker sheets (mic choice, template, translate-language, tag, auto-tag) already expose an explicit Cancel/Done or Cancel/Save toolbar action; no further change needed.

**Acceptance met:** the app's confirmation/alert surfaces are consistently `kurnDialog` (decisions) or `.confirmationDialog` (contextual choice among 3+ options), with the one-line exception now folded in; no destructive action renders in a non-destructive color; every sheet has a discoverable dismiss path independent of swipe.

### D3 — Dynamic Type coverage
**Status: Done**

- ✅ F11: all ~35 `.font(.system(size:))` call sites were triaged individually. Real content next to or standing for text (checkmarks, chevrons, list icons, chat timestamp/citation icons) moved to a matching `Theme` semantic font or a scalable `.system(.textStyle, weight:)` call — the same construction `Theme.swift` itself uses, so it required no new API. Icons genuinely constrained by a small fixed well/circle/grid-cell (folder icon/color pickers, the chat composer's send/stop buttons, `kurnDialog`'s icon, avatar initials, `RecorderView`'s transport controls) were left at a fixed size with an inline comment explaining why scaling them would overflow their container — the same reasoning `RecorderView`'s existing `@ScaledMetric` exception already documents.
- ✅ F12: confirmed `SummaryView.swift:80`'s size-6 `circle.fill` is a decorative, `.accessibilityHidden` bullet marker, not text. No change needed.

**Acceptance met:** no `.font(.system(size:))` call site lacks either a `Theme`/scalable semantic font or an inline comment documenting a fixed-geometry exception.

### D4 — Unify primary-button visual language
**Status: Done — rescoped to a decision plus targeted fixes, not a full migration**

- ✅ Added a "Button language" section to `Theme.swift` naming exactly one style per situation: `.glassProminent` + `Theme.accent` for a screen's primary action, `.bordered` for a secondary action alongside one, `kurnDialog` for confirmation/destructive decisions (not a bespoke button — see D2/F1/F2 corrections), and `.plain` for list/menu rows and chips.
- ✅ F10: resolved by that decision — the `.borderedProminent` outlier (F8) is fixed, and `kurnDialog` is confirmed correct rather than a fourth competing language, so no fourth visual language remains for "primary action of a screen."
- ✅ F9, addressed by decision rather than mass migration: most of the ~45 `.buttonStyle(.plain)` sites are list/menu rows or chips, which the decision table now makes an explicit, correct choice, not an oversight. The two sites that actually were a screen's single primary CTA drawn as a hand-rolled colored rectangle — `LockedRecordingsView`'s "Unlock" button (`MeetingsListComponents.swift`) and `ModelStoreRecoveryView`'s "Retry" button (`ModelStoreBootViews.swift`) — were migrated to `.glassProminent`.

**Acceptance met:** a documented button-style decision table exists in `Theme.swift`; the app has at most one visual language for "primary action of a screen." Full migration of every `.plain` site was deliberately not attempted — see the priority matrix note below.

### D5 — Contrast verification pass
**Status: Done**

- ✅ F13 verified, no change needed: the `Color.black.opacity(0.42)` scrim (`DesignComponents.swift:193`) sits behind the dialog card to dim whatever was on screen, the same role the system's own `.sheet`/`.alert` dimming layer plays — WCAG contrast criteria apply to text/UI-component contrast, not to a background-dimming layer, and the card's own text still reads against the adaptive `Theme.surface`. No render was needed to settle this, only the reasoning.
- ✅ F14 confirmed and fixed by manual WCAG computation (no render needed — the color values are known constants): white text on `Theme.accent` (#FF3B30) measures **~3.55:1**, and on `Theme.info` (#0A84FF) **~3.65:1** — both below the 4.5:1 AA floor for normal text, though above the 3:1 floor for "large text" (≥14pt bold). Fixed by bumping `kurnDialog`'s primary-button label from `Theme.footnoteEmphasized` (13pt semibold) to bold `.subheadline` (15pt bold) in `DesignComponents.swift`, which clears the large-text 3:1 bar without changing the brand colors used identically across the app.
- ✅ F15 verified safe by computation: `RecorderView`'s white text sits on a background whose worst case (center of the radial gradient, `.recording` state) is `Theme.accent` at 12% opacity over black — a luminance of ~0.0045, giving white text a contrast of **~19:1**, far above even AAA (7:1). The forced-dark exception is confirmed safe as documented, no change needed.

**Acceptance met:** all three contrast questions have a measured answer; one (F14) needed and received a fix.

### D6 — iPad adaptation (NavigationSplitView)
**Status: Done**

- ✅ F6: `ContentView` (previously a bare `NavigationStack { MeetingsListView() }`) now branches on `@Environment(\.horizontalSizeClass)`. On `.regular`, it renders `NavigationSplitView { FolderSidebarView(selection: $selection) } detail: { NavigationStack { MeetingsListView(selection: $selection) } }`; on compact, the original `NavigationStack { MeetingsListView(selection: $selection) }` is unchanged. `selection` moved from `MeetingsListView`'s own `@State` up to `ContentView`, passed down as a `Binding` — `MeetingsListView`'s property changed from `@State var selection` to `@Binding var selection`, which needed no other change in that file since every other reference already read `selection` as a plain value (unaffected by the property-wrapper swap). `MeetingsListToolbar`'s `libraryButton` (which used to open `FolderSidebarView` as a sheet) is hidden on `.regular` width, since the same picker is now always visible in the sidebar column and the button would just duplicate it — checked via `@Environment(\.horizontalSizeClass)` read in `MeetingsListView` too.
- `FolderSidebarView` needed no structural change: it already only depended on a `Binding<LibrarySelection>` and its own internal `NavigationStack(path:)` for drill-down, which works identically whether hosted as sheet content or as a `NavigationSplitView` sidebar column. Its `dismiss()` calls after a selection become harmless no-ops in the sidebar case (nothing modal to dismiss).
- Confirmed no watchOS/Live Activity target references any of the touched files (`ContentView.swift`, `MeetingsListView.swift`, `MeetingsListToolbar.swift`, `FolderSidebarView.swift`) — this is isolated to the main `Kurn` app target.
- **Not done this session, flagged for a maintainer with an iPad simulator**: a real visual/interaction pass (does the split view balance correctly, does the sidebar collapse/expand as expected in Split View/Slide Over, does VoiceOver traverse sidebar → detail sensibly). This is exactly the kind of check this Linux session cannot perform — verify through CI plus a manual iPad simulator pass before considering the visual result final, even though the acceptance criterion below is met structurally.

**Acceptance met:** on iPad in regular width, folders/smart folders render in a persistent sidebar column rather than a full-screen sheet; iPhone/compact behavior is unchanged (same sheet, same toolbar button, same `NavigationStack`).

### D7 — RecorderView accessibility gaps
**Status: Done**

- ✅ F16, rescoped during implementation: combining the full status+timer+highlight cluster into one VoiceOver element would have required moving `startingIndicator` out from between `statusBadge` and `timer` in the view tree (SwiftUI accessibility grouping requires the grouped views to share a container), which is a layout change with no accessibility justification of its own — reverted after an initial attempt reordered it. `statusBadge` was already effectively a single node (its icon is `.accessibilityHidden`), so the real two-separate-nodes problem was only inside `timer` (elapsed time and highlight count), which now combines into one composed label ("12:34, 2 highlights") exactly when there's a count to report, with **zero layout change**. New localization key `recorder.accessibility.timer_with_highlights` (all 7 locales); `recorder.title_field.accessibility_label` (F17) unaffected.
- ✅ F17: the meeting-title `TextField` now carries an explicit `.accessibilityLabel` (new key `recorder.title_field.accessibility_label`, all 7 locales), independent of its placeholder text.
- Not done this session: bringing `RecorderView` into `KurnUITests/AccessibilityAuditUITests.swift`'s coverage — left as a follow-up, since it needs a macOS/Xcode toolchain to write and verify against.

**Acceptance met (revised):** the elapsed-time/highlight-count pair reads as one composed phrase instead of two unrelated stops, without changing the screen's layout; the title field has a label that survives once text is entered. Audit-suite coverage remains a follow-up.

### D8 — Consolidate empty states
**Status: Done**

- ✅ F18: `MeetingsListView`'s and `ChatSessionListView`'s hand-rolled `VStack` empty states were removed and replaced with `ContentUnavailableView`, matching the pattern already used in `DocumentsListView.swift`/`DocumentCreateView.swift`. No `actions:` CTA was added — the existing copy in both ("Tap + to create your first meeting…") refers to chrome outside the empty state itself (the toolbar's record button / the Ask sheet's own entry points), so adding a duplicate in-view action would have been a second way to do the same thing rather than a clarification.

**Acceptance met:** every empty state in the app is now a `ContentUnavailableView`; zero hand-rolled `VStack`-based empty states remain.

## Priority matrix

| # | Track | Effort | Impact | Quadrant | Outcome |
|---|-------|--------|--------|----------|---------|
| 1 | D1 (all three fixes) | Low | Medium–High | Do now | ✅ Done |
| 2 | D2 (rescoped) | Low | Medium | Do now | ✅ Done |
| 3 | D8 | Low–Medium | Medium | Do now | ✅ Done |
| 4 | D3 | Medium | High | Prioritize next | ✅ Done |
| 5 | D5 | Low (verification) / Medium (if fixes needed) | Medium | Prioritize next | ✅ Done |
| 6 | D7 | Low–Medium | Medium | Prioritize next | ✅ Done |
| 7 | D4 (rescoped: decision table + 2 concrete outliers) | Low–Medium | Medium | Prioritize next | ✅ Done |
| 8 | D6 | High | High | Plan as a project — the single most structural item in this review | ✅ Done (structural change landed; needs a manual iPad simulator pass, see D6 above) |

D4's full scope (migrating all ~45 `.buttonStyle(.plain)` sites) was intentionally *not* attempted wholesale: the button-language decision table in `Theme.swift` now makes `.plain` for list/menu rows an explicit, correct choice rather than an oversight, so most of those 45 sites needed no change — only the two screens whose single primary CTA still used a hand-drawn rectangle did.

## Change log

- 2026-09-26 — Initial review and remediation plan created. All tracks D1–D8 open, no work landed yet.
- 2026-09-26 — Implemented D1, D2 (rescoped), D3, D4 (rescoped), D5, D7, D8. D6 (iPad `NavigationSplitView`) deferred to a dedicated session by explicit user decision, given its architectural scope and the impossibility of verifying iPad layout in this Linux session. Two review findings (F1, and F2's original direction) were corrected during implementation — see "Corrections found during implementation" above. All local, Linux-runnable checks pass (`Tools/check_static_policy.py`, the CI localization key-parity check reproduced locally); full compile/test verification still requires a macOS/Xcode CI run, per this project's usual workflow for changes made without a local toolchain.
- 2026-09-26 — Added a "Modal weight" section to `Theme.swift`, next to the button-language table, naming the second axis D2 only implied: a quick binary decision (`kurnDialog`/native alert) vs. a decision carrying genuine extra content (a real `.sheet`, using `CrossMeetingSpeakerMatchView`'s voice-match confirmation as the reference example). This was prompted by a follow-up question about standardizing on that sheet's format — the answer was "yes for content-rich decisions, no for simple ones," now written down instead of left as an ad-hoc call.
- 2026-09-26 — Implemented D6: `ContentView` now adopts `NavigationSplitView` on regular width with `FolderSidebarView` as a persistent sidebar column, falling back to the original sheet-based `NavigationStack` on compact width. All 8 tracks are now implemented; the only outstanding item across the whole review is a manual iPad-simulator verification pass for D6, which this Linux session cannot perform.
