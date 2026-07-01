//
//  TagChipsView.swift
//  Kurn
//
//  Small, reusable tag chips shown in the meetings list card and in the meeting
//  detail header.
//

import SwiftUI

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
        HStack(spacing: 6) {
            ForEach(visibleTags) { tag in
                Text(tag.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: tag.colorHex))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Color(hex: tag.colorHex).opacity(0.12),
                        in: Capsule()
                    )
            }
            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.fill, in: Capsule())
            }
        }
    }
}
