import SwiftUI

// The Knowledge screens' look, taken from the screens that came before them so
// the two read as one app (CLAUDE.md "Navigation chrome"): section labels like
// `MeetingDetailView.sectionLabel`, cards like `kurnCard`, secondary actions
// like the summary tab's `FilterChip` capsules, rows like `DocumentsListView`'s
// (an accent icon well, primary text, secondary detail) on `Theme.background`.
// No action is left as a bare tinted text link.

/// An uppercase, tracked section title in the tertiary colour.
struct KnowledgeSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.caption2Emphasized)
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded accent well holding an SF Symbol, as in the documents list.
struct KnowledgeIconWell: View {
    let systemImage: String
    var tint: Color = Theme.accent

    var body: some View {
        Image(systemName: systemImage)
            .font(Theme.callout)
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A secondary action drawn like the summary tab's chips: a grey capsule with
/// footnote text, never the system tint.
struct KnowledgeChipLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(title).lineLimit(2)
        }
        .font(Theme.footnoteEmphasized)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.fill, in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct KnowledgeChipButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { KnowledgeChipLabel(title: title, systemImage: systemImage) }
            .buttonStyle(.plain)
    }
}

/// The trailing disclosure chevron of a tappable card.
struct KnowledgeChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(Theme.footnoteEmphasized)
            .foregroundStyle(Theme.textTertiary)
            .accessibilityHidden(true)
    }
}

/// A card that opens a route: the content, a chevron, on a `kurnCard`.
struct KnowledgeLinkCard<Route: Hashable, Content: View>: View {
    let route: Route
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationLink(value: route) {
            HStack(alignment: .center, spacing: 12) {
                content().frame(maxWidth: .infinity, alignment: .leading)
                KnowledgeChevron()
            }
            .kurnCard(padding: 14, cornerRadius: 16)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A quoted source passage: body text set off by a bar, like a block quote.
struct KnowledgeQuote: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.separator).frame(width: 3).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The scrolling reading surface every Knowledge page sits on.
    func knowledgeReadingSurface() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// A card in the Knowledge screens: `kurnCard` with the meeting tabs' 16pt corners.
    func knowledgeCard() -> some View {
        kurnCard(padding: 16, cornerRadius: 16)
    }
}
