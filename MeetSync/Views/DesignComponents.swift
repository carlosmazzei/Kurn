//
//  DesignComponents.swift
//  MeetSync
//
//  Reusable UI building blocks from the iOS design handoff: the status pill,
//  filter chips, and the rounded card surface. Kept in one place so every screen
//  shares the exact same tokens (radii, colors, padding).
//

import SwiftUI

/// Small colored pill showing a transcription status (dot + label).
struct StatusBadge: View {
    let status: TranscriptionStatus

    var body: some View {
        if let label {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
        }
    }

    private var label: String? {
        switch status {
        case .none: return NSLocalizedString("status.todo", comment: "To transcribe")
        case .inProgress: return NSLocalizedString("status.in_progress", comment: "")
        case .done: return NSLocalizedString("status.done", comment: "")
        case .failed: return NSLocalizedString("status.failed", comment: "")
        }
    }

    private var color: Color {
        switch status {
        case .none: return Theme.info
        case .inProgress: return Theme.warning
        case .done: return Theme.success
        case .failed: return Theme.accent
        }
    }
}

/// Selectable rounded chip used for list filters and speaker filters.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    /// Optional accent (e.g. a speaker color). Defaults to the primary label.
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? selectedForeground : Theme.textSecondary)
                .background(
                    isSelected ? AnyShapeStyle(selectedBackground) : AnyShapeStyle(Theme.fill),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private var selectedBackground: Color {
        tint == .primary ? .primary : tint.opacity(0.18)
    }

    private var selectedForeground: Color {
        tint == .primary ? Color(uiColor: .systemBackground) : tint
    }
}

extension View {
    /// The standard rounded card surface (#1C1C1E in dark) used across screens.
    func meetsyncCard(padding: CGFloat = 16, cornerRadius: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
