//
//  TagChipsView.swift
//  Kurn
//
//  Small, reusable tag chips shown in the meetings list card and in the meeting
//  detail header.
//

import SwiftUI

struct TagChip: View {
    let tag: Tag

    var body: some View {
        Text(tag.name)
            .font(.system(.caption2, design: .default, weight: .medium))
            .foregroundStyle(Color(hex: tag.colorHex))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color(hex: tag.colorHex).opacity(0.12),
                in: Capsule()
            )
    }
}

struct TagChipsView: View {
    let tags: [Tag]
    var maxVisible: Int?

    private var visibleTags: [Tag] {
        guard let maxVisible else { return tags }
        return Array(tags.prefix(maxVisible))
    }

    private var overflowCount: Int {
        guard let maxVisible else { return 0 }
        return max(0, tags.count - maxVisible)
    }

    var body: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(visibleTags) { tag in
                TagChip(tag: tag)
            }
            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.fill, in: Capsule())
            }
        }
    }
}
