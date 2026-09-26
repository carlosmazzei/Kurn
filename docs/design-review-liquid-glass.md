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

## Findings register

Each finding below is tagged with the track (D1–D8) that will fix it. Severity
follows the original review: Crítico / Alto / Médio / Baixo.

| ID | Finding | File(s) | Severity | Track |
|----|---------|---------|----------|-------|
| F1 | `kurnDialog`'s destructive button uses `Theme.accent`, not a semantic red — a destructive action is visually indistinguishable from a normal primary action | `DesignComponents.swift:298` | Crítico | D2 |
| F2 | Three competing confirmation mechanisms: native `.alert` (1 use), native `.confirmationDialog` (3 uses), custom `kurnDialog` (~25 uses) that redraws system-alert chrome with `RoundedRectangle` buttons | `DesignComponents.swift:230-316` + ~25 call sites | Alto | D2 |
| F3 | Only 3 of ~38 sheets use `.presentationDetents`; short utility pickers (mic choice, summary template, translate language, tag picker) open full-height by default | `CrossMeetingSpeakerMatchView.swift:86`, `MeetingShareSelectionView.swift:89`, `MeetingsListView.swift:347`, and the pickers lacking detents | Médio | D1 |
| F4 | `RecorderView`'s dismiss chrome (title-bar "Cancel" text only, no Done/X) differs from the Cancel/Done toolbar pattern used by `MeetingFormView`/`DocumentCreateView`, and from the Share sheet's pure-swipe pattern | `RecorderView.swift:110-117,177` | Médio | D2 |
| F5 | Sheets for mic choice / template picker / translate-language picker / tag picker have no confirmed toolbar dismiss at the call site | Various pickers | Baixo–Médio (unconfirmed) | D2 |
| F6 | No `NavigationSplitView` or `.horizontalSizeClass` anywhere in the codebase; `FolderSidebarView` is a `.sheet`-presented `NavigationStack`, not a persistent sidebar column, despite the app being declared universal | Whole codebase; `FolderSidebarView.swift` | Crítico (estrutural) | D6 |
| F7 | Single `.background(.bar)` leftover, likely a pre-Liquid-Glass custom bottom bar | `DocumentCreateView.swift:150` | Médio | D1 |
| F8 | Sole remaining `.buttonStyle(.borderedProminent)` in the app, in the same recording/detail journey where `RecorderView`'s Stop button uses `.glassProminent` | `MeetingDetailView.swift:520` | Alto | D1 |
| F9 | ~45 uses of `.buttonStyle(.plain)` with hand-drawn backgrounds standing in for real buttons, each reimplementing press feedback and material independently | `DesignComponents.swift:139,314`, `FolderPickerView.swift`, `MeetingChatView.swift`, `TagManagementView.swift`, others | Médio | D4 |
| F10 | Four coexisting "primary button" visual languages: `.glassProminent`, `.borderedProminent`, `kurnDialog`'s custom colored buttons, and unstyled `.plain` rows | App-wide | Alto | D4 |
| F11 | ~35 call sites use `.font(.system(size:))` with no `@ScaledMetric`/Theme font, so that text does not scale with Dynamic Type unlike the rest of the app | `FolderSidebarView.swift`, `MeetingChatView.swift`, `FilterBarView.swift`, `TranscriptView.swift`, ~30 more (full list in review transcript) | Alto | D3 |
| F12 | `SummaryView.swift:80` uses `.font(.system(size: 6))` — verify whether decorative or real text | `SummaryView.swift:80` | Médio (pending verification) | D3 |
| F13 | `DesignComponents.swift:193` scrim uses fixed `Color.black.opacity(0.42)` instead of an adaptive `Material` | `DesignComponents.swift:193` | Médio (not verifiable without render) | D5 |
| F14 | `DesignComponents.swift:300` uses fixed `Color.white` foreground on `kurnDialog`'s primary button, whose background is `Theme.accent` — contrast in light mode unverified | `DesignComponents.swift:300` | Médio (not verifiable without render) | D5 |
| F15 | `RecorderView`'s forced dark backdrop (`Color.black`, `.preferredColorScheme(.dark)`) and white text are an intentional, documented exception, but were never validated for WCAG AA contrast against the radial-gradient background | `RecorderView.swift:77,121,208,211,222,241,279,381` | Baixo (known, accepted exception) | D5 |
| F16 | Recorder's status/timer/highlight-count cluster has no `.accessibilityElement(children: .combine)`, so VoiceOver announces three unrelated elements instead of one composed status | `RecorderView.swift` status cluster | Médio | D7 |
| F17 | Recorder's title `TextField` has no explicit `.accessibilityLabel`, relying on the placeholder, which VoiceOver stops reading once the field has a value | `RecorderView.swift:233-247` | Médio | D7 |
| F18 | Three divergent empty-state implementations: `ContentUnavailableView` (Documents, 2 uses) vs. two independently hand-rolled, near-identical `VStack` empty states | `DocumentsListView.swift:28`, `DocumentCreateView.swift:212`, `MeetingsListView.swift:424-438`, `ChatSessionListView.swift:95-109` | Médio | D8 |

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
**Status: Open**

- Fix F8: change `MeetingDetailView.swift:520` from `.buttonStyle(.borderedProminent)` to `.buttonStyle(.glassProminent)` with `.tint(Theme.accent)`, matching `RecorderView`'s Stop button.
- Fix F3: add `.presentationDetents([.medium])` (or `[.medium, .large]` where content can grow, e.g. the template list) to the short utility pickers: mic choice, summary template picker, translate-language picker, tag picker.
- Fix F7: replace `DocumentCreateView.swift:150`'s `.background(.bar)` with a `ToolbarItem`/`.safeAreaBar` using `.glassProminent`, consistent with `MeetingsListToolbar`.

**Acceptance:** no more `.borderedProminent` in the codebase; the four named pickers open at `.medium` height; zero remaining `.background(.bar)` matches outside intentional system chrome.

### D2 — Unify confirmation/alert mechanisms
**Status: Open**

- Fix F1 first as a standalone, minimal patch (change `kurnDialog`'s destructive button color to the system red), since it's the most severe individual finding and safe to ship independently of the larger F2 migration.
- Fix F2: migrate `kurnDialog` call sites to native `.alert(_:isPresented:actions:)` wherever the situation is a simple binary confirmation (the majority of the ~25 uses). Keep a custom component only where content genuinely exceeds what `.alert` supports.
- Fix F4: align `RecorderView`'s exit affordance with the Cancel/Done vocabulary used by `MeetingFormView`/`DocumentCreateView`; keep the swipe-disable guard during active recording, but make the exit action's label reflect its real consequence (e.g. a destructive "Discard" once a recording exists).
- Resolve F5: read the picker views' bodies to confirm whether they have their own dismiss affordance; if not, add a minimal `.cancellationAction` toolbar item, with particular attention to iPad/Mac Catalyst where swipe-to-dismiss may not be discoverable.

**Acceptance:** every confirmation/alert in the app is either a native `.alert`, a native `.confirmationDialog`, or a documented exception; no destructive action renders in a non-destructive color; every sheet has a discoverable dismiss path independent of swipe.

### D3 — Dynamic Type coverage
**Status: Open**

- Fix F11: audit and replace the ~35 `.font(.system(size:))` call sites with `Theme`'s semantic fonts where the text is real content (timestamps, chip labels, captions). Where a fixed size is intentional (a decorative glyph, a small badge), wrap in `@ScaledMetric`, following the pattern already used correctly in `RecorderView.swift:72,220`.
- Resolve F12: confirm whether `SummaryView.swift:80`'s size-6 font is decorative; if not, raise it to at least `.caption2` with `@ScaledMetric` if a small size is still required by design.

**Acceptance:** no `.font(.system(size:))` call site outside `RecorderView`'s documented fixed-geometry exception lacks either a `Theme` semantic font or `@ScaledMetric`.

### D4 — Unify primary-button visual language
**Status: Open**

- Define, in `Theme.swift` (or a short new "Button language" note near it), which style corresponds to: primary action of a screen, secondary action, and destructive confirmation. This is a decision to write down once, not a per-file judgment call each time.
- Fix F10 by migrating outliers to that definition, starting with any screen's single clearest "primary action of this screen" button.
- Fix F9 opportunistically as touched: prioritize `.plain`-styled elements that function as a screen's primary action over incidental list/menu rows, which may legitimately stay `.plain`.

**Acceptance:** a documented button-style decision table exists; the app has at most one visual language for "primary action of a screen" (excluding `kurnDialog`'s buttons, which D2 either removes or brings in line).

### D5 — Contrast verification pass
**Status: Open**

- Resolve F13: test `DesignComponents.swift:193`'s `Color.black.opacity(0.42)` scrim in Dark Mode; replace with an adaptive `Material` if contrast is insufficient.
- Resolve F14: measure `Color.white` on `Theme.accent` (light mode) for `kurnDialog`'s primary button against WCAG AA (4.5:1); switch to an adaptive foreground if it fails. Superseded by D2 wherever `kurnDialog` itself is migrated to native `.alert`.
- Resolve F15: manually check WCAG AA contrast for `RecorderView`'s white text against its radial-gradient background at both ends of the gradient. No structural change expected — this is a verification, not a redesign, of an accepted exception.

**Acceptance:** all three contrast questions above have a measured answer (pass/fail with the actual ratio), not an assumption.

### D6 — iPad adaptation (NavigationSplitView)
**Status: Open — largest single track, treat as its own mini-project**

- Fix F6: introduce `NavigationSplitView` with the folder/smart-folder list as a persistent sidebar column when `.horizontalSizeClass == .regular` (iPad, and Mac Catalyst if applicable), keeping the existing `.sheet`-presented `FolderSidebarView` as the compact/iPhone fallback.
- Scope this as a dedicated design + implementation pass, not a drive-by fix — it touches the app's navigation architecture (`Views/FolderSidebarView.swift` and whatever hosts the root navigation), not just a modifier.

**Acceptance:** on iPad in regular width, folders/smart folders render in a persistent sidebar column rather than a full-screen sheet; iPhone/compact behavior is unchanged.

### D7 — RecorderView accessibility gaps
**Status: Open**

- Fix F16: wrap the status/timer/highlight-count cluster in `.accessibilityElement(children: .combine)` with a composed label (e.g. "Recording, 12:34, 2 highlights").
- Fix F17: add an explicit `.accessibilityLabel` to the meeting-title `TextField`, independent of its placeholder text.
- Once F16/F17 land, consider bringing `RecorderView` into `KurnUITests/AccessibilityAuditUITests.swift`'s coverage (currently explicitly excluded per CLAUDE.md), adapting the audit for its fixed immersive layout.

**Acceptance:** VoiceOver announces the Recorder's live status as one composed phrase; the title field has a label that survives once text is entered; `RecorderView` has a tracked path to audit coverage (even if not landed in this track).

### D8 — Consolidate empty states
**Status: Open**

- Fix F18: migrate `MeetingsListView.swift:424-438` and `ChatSessionListView.swift:95-109` to `ContentUnavailableView`, with `actions:` for the relevant CTAs ("Record a meeting", "New conversation"), matching the pattern already used in `DocumentsListView.swift:28` and `DocumentCreateView.swift:212`.

**Acceptance:** every empty state in the app is a `ContentUnavailableView`; zero hand-rolled `VStack`-based empty states remain.

## Priority matrix

| # | Track | Effort | Impact | Quadrant |
|---|-------|--------|--------|----------|
| 1 | D1 (all three fixes) | Low | Medium–High | Do now |
| 2 | D2 — F1 only (destructive color) | Low | High | Do now |
| 3 | D8 | Low–Medium | Medium | Do now |
| 4 | D3 | Medium | High | Prioritize next |
| 5 | D5 | Low (verification) / Medium (if fixes needed) | Medium | Prioritize next |
| 6 | D7 | Low–Medium | Medium | Prioritize next |
| 7 | D2 — remaining `kurnDialog` migration | High | High | Plan as a project |
| 8 | D4 (full unification) | High | High | Plan as a project |
| 9 | D6 | High | High | Plan as a project — the single most structural item in this review |

## Change log

- 2026-09-26 — Initial review and remediation plan created (this document). All tracks D1–D8 open, no work landed yet.
