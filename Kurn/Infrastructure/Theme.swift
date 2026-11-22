//
//  Theme.swift
//  Kurn
//
//  Design-system tokens derived from the iOS design handoff. Colors are adaptive
//  (the handoff specifies the dark-mode palette; light-mode falls back to the
//  matching system materials), so the app honors the system appearance while
//  matching the mock pixel-for-pixel in dark mode.
//

import SwiftUI

/// Semantic colour roles: pick a role, not a raw palette colour.
///
/// - `ink` — the label colour (black in light, white in dark): selected chips,
///   primary filled buttons, active toolbar controls, progress fills.
/// - `onInk` — text/glyph drawn on an `ink`-filled control.
/// - `link` — blue: inline text actions ("Add…"), checkmarks in selectable
///   lists, selection indicators, a search field's Cancel.
/// - `record` — red: the Record action and the live recording state only.
/// - `destructive` — red: delete/remove/reset actions and failure states only.
/// - `indicator` — grey glyphs in list rows (favourite, transcript, summary).
/// - `favorite` — amber: the favourited star in the meeting toolbar.
///
/// Red never appears outside `record`/`destructive`.
enum Theme {
    // MARK: - Palette

    /// App background (behind scroll content). Pure black in dark mode.
    static let background = adaptive(dark: 0x000000, light: nil, lightSystem: .systemGroupedBackground)
    /// "Paper" surface for long reading text (summary, transcript, wiki,
    /// documents). Not applied anywhere yet.
    static let readingBackground = Color(uiColor: .systemBackground)
    /// Elevated surface for cards / grouped rows (#1C1C1E in dark).
    static let surface = adaptive(dark: 0x1C1C1E, light: nil, lightSystem: .secondarySystemGroupedBackground)
    /// Subtle fill (chips, icon wells) — opaque #2C2C2E in dark.
    static let fill = Color(uiColor: UIColor { t in
        if t.userInterfaceStyle == .dark {
            return UIColor(rgb: t.accessibilityContrast == .high ? 0x3A3A3C : 0x2C2C2E)
        }
        return t.accessibilityContrast == .high ? UIColor.systemGray4 : UIColor.systemGray5
    })

    /// Brand / record / destructive accent. Light mode uses a deeper red
    /// (#B31912, 7.1:1 on white and >6.0:1 on tinted pills) so red text/glyphs
    /// on light cards and status badges meet WCAG AA 4.5:1 contrast.
    ///
    /// Deprecated in spirit: use `record` or `destructive`; no new call sites.
    static let accent = adaptive(dark: 0xFF453A, light: 0xB31912, lightSystem: .systemRed)
    /// Filled button background for destructive primary actions with white text
    /// (#D92B21 in both appearances: 4.86:1 with white text and 3.50:1 against #1C1C1E).
    static let accentFill = Color(hex: "#D92B21")
    /// Status green: #32D74B in dark (8.9:1 on #1C1C1E), #116629 in light (7.07:1 on white, >6.0:1 on tinted pill).
    static let success = adaptive(dark: 0x32D74B, light: 0x116629, lightSystem: .systemGreen)
    /// Interactive / informational blue: #409CFF in dark (6.1:1 on #1C1C1E), #004A9F in light (8.4:1 on white).
    static let info = adaptive(dark: 0x409CFF, light: 0x004A9F, lightSystem: .systemBlue)
    /// Filled button background for non-destructive primary dialog actions with
    /// white text (#0B66D6 in both appearances: 5.40:1 with white text and 3.15:1 against #1C1C1E).
    static let infoFill = Color(hex: "#0B66D6")
    /// Status amber: #FF9F0A in dark (8.3:1 on #1C1C1E), #854600 in light (7.16:1 on white, >6.0:1 on tinted pill).
    static let warning = adaptive(dark: 0xFF9F0A, light: 0x854600, lightSystem: .systemOrange)
    /// Camera viewfinder focus/zoom accent over dark live preview.
    static let cameraAccent = Color(hex: "#FFD60A")

    /// Hairline separator matching the mock (#38383A opaque in dark; boosted under Increase Contrast).
    static let separator = Color(uiColor: UIColor { t in
        if t.userInterfaceStyle == .dark {
            return UIColor(rgb: t.accessibilityContrast == .high ? 0x545458 : 0x38383A)
        }
        return t.accessibilityContrast == .high ? UIColor.opaqueSeparator : UIColor.separator
    })

    // MARK: - Colour roles

    /// Label colour (black in light, white in dark): selected chips, primary
    /// filled buttons, active toolbar controls, progress fills.
    static let ink = Color.primary
    /// Text/glyph drawn on an `ink`-filled control.
    static let onInk = Color(uiColor: .systemBackground)
    /// Red: the Record action and the live recording state only.
    static let record = accent
    /// Red: delete/remove/reset actions and failure states only.
    static let destructive = accent
    /// Blue: inline text actions ("Add…", checkmarks in selectable lists,
    /// selection indicators, a search field's Cancel).
    static let link = info
    /// Grey glyph indicators in list rows (favourite, transcript, summary).
    /// The prototype's lighter grey (#A5A5AA) fails 3:1 against the dark
    /// background, so this stays at `textTertiary`.
    static let indicator = textTertiary
    /// Amber star for the favourite toggle in the meeting toolbar.
    static let favorite = warning

    // MARK: - Text

    static let textPrimary = Color.primary
    static let textSecondary = Color(uiColor: UIColor { t in
        if t.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(t.accessibilityContrast == .high ? 0.88 : 0.74)
        }
        return t.accessibilityContrast == .high ? UIColor(rgb: 0x3A3A3E) : UIColor(rgb: 0x48484D)
    })
    /// Secondary/metadata text token guaranteed to meet >= 4.5:1 contrast on
    /// both `background` and `surface` in dark and light appearances.
    static let textTertiary = Color(uiColor: UIColor { t in
        if t.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(t.accessibilityContrast == .high ? 0.82 : 0.68)
        }
        return t.accessibilityContrast == .high ? UIColor(rgb: 0x3A3A3E) : UIColor(rgb: 0x56565C)
    })
    /// Decorative-only tertiary token for non-text borders and inactive rules
    /// that do not carry readable information.
    static let decorationTertiary = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.3)
            : UIColor.tertiaryLabel
    })

    // MARK: - Typography

    /// Dynamic-Type-aware replacements for the fixed `.font(.system(size:))` call
    /// sites throughout the app. `Font.system(_:design:weight:)` (unlike
    /// `Font.system(size:weight:)`) scales with the user's text size setting, so
    /// migrating a call site to one of these (see Views for the largest offenders)
    /// restores Dynamic Type support without hand-picking a new point size.
    /// Fixed-size geometry (e.g. the recorder's timer digits) is a deliberate
    /// exception — see `RecorderView`'s use of `@ScaledMetric` with a capped
    /// `dynamicTypeSize` instead of these tokens.
    static let title = Font.system(.title2, design: .default, weight: .bold)
    static let title3 = Font.system(.title3, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body, design: .default)
    static let bodyEmphasized = Font.system(.body, design: .default, weight: .semibold)
    static let callout = Font.system(.callout, design: .default)
    static let calloutEmphasized = Font.system(.callout, design: .default, weight: .semibold)
    static let subheadline = Font.system(.subheadline, design: .default)
    static let subheadlineEmphasized = Font.system(.subheadline, design: .default, weight: .semibold)
    static let footnote = Font.system(.footnote, design: .default)
    static let footnoteEmphasized = Font.system(.footnote, design: .default, weight: .semibold)
    static let caption = Font.system(.caption, design: .default)
    static let captionEmphasized = Font.system(.caption, design: .default, weight: .semibold)
    static let caption2 = Font.system(.caption2, design: .default)
    static let caption2Emphasized = Font.system(.caption2, design: .default, weight: .semibold)

    // MARK: - Spacing & radius

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 8
        static let chip: CGFloat = 12
        static let card: CGFloat = 18
        static let sheet: CGFloat = 26
    }

    // MARK: - Button language
    //
    // Which `.buttonStyle` a control gets is a decision, not a per-file
    // judgment call. Four visual languages once coexisted: pick from this
    // table instead of adding a fifth.
    //
    // - **Primary action of a screen** (the one thing this screen exists to
    //   let you do — Stop recording, download a model, confirm a share):
    //   `.buttonStyle(.glassProminent)` with `.tint(Theme.ink)` and the label
    //   in `Theme.onInk`. The Record button and destructive primaries use
    //   `Theme.record` / `Theme.destructive` instead (white label). This is
    //   the Liquid Glass default; prefer it over `.borderedProminent` (kept
    //   only where the OS itself renders the control, e.g. inside a native
    //   `.alert`).
    // - **Secondary action alongside a primary one** (Cancel next to
    //   Generate, a form's secondary button): `.buttonStyle(.bordered)`.
    // - **Confirmation/destructive decision** (delete, reset, restore):
    //   `kurnDialog` (`DesignComponents.swift`), not a bespoke button — the
    //   deliberate app-wide convention (`errorAlert` wraps it), required
    //   as-is by `KurnUITests/Flows/LibraryFlowUITests`/`SettingsFlowUITests`
    //   (CLAUDE.md, "Navigation chrome").
    // - **List/menu row, chip, or other incidental tap target** that is not
    //   "the action this screen is for": `.buttonStyle(.plain)` with custom
    //   content remains correct — most of the app's `.plain` buttons are
    //   this case and do not need migrating.

    // MARK: - Modal weight
    //
    // Two confirmation shapes exist on purpose — pick by content, not by
    // habit or by which one looks nicer for a given screen.
    //
    // - **A quick binary decision with no illustration or extra context**
    //   ("Delete this tag?", "Restore this backup?"): `kurnDialog` (or a
    //   native `.alert`/`.confirmationDialog` where the OS must own the
    //   control). Reserve this for exactly what HIG reserves alerts for —
    //   essential, short, low-effort decisions that shouldn't cost more than
    //   a glance and a tap.
    // - **A decision that carries genuine extra content** — an illustration,
    //   an explanation the user should actually read, more than one line of
    //   context (`CrossMeetingSpeakerMatchView`'s voice-match confirmation is
    //   the reference example): a real `.sheet` with `NavigationStack`, an
    //   inline title, a `.cancellationAction` toolbar button, and full-width
    //   `.glassProminent`/`.glass` buttons, sized with
    //   `.presentationDetents([.medium])` (or `[.medium, .large]` if the
    //   content can grow). This is the same "content sheet" shape
    //   `MeetingShareSelectionView`/`SummaryTemplatePicker`/`MeetingFormView`
    //   already use — reuse it rather than inventing a third shape.
    //
    // Do not promote the sheet shape to a house style for every confirmation:
    // wrapping a one-line "Delete this tag?" in a `NavigationStack` sheet asks
    // for more attention and more steps (an extra transition, a swipe-down or
    // Cancel tap) than that task needs, which is the same "simplicity" failure
    // a plain alert avoids by design.

    // MARK: - Helpers

    private static func adaptive(dark: Int, light: Int?, lightSystem: UIColor) -> Color {
        Color(uiColor: UIColor { t in
            if t.userInterfaceStyle == .dark { return UIColor(rgb: dark) }
            if let light { return UIColor(rgb: light) }
            return lightSystem
        })
    }
}

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
