//
//  DesignComponents.swift
//  Kurn
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

enum KurnDialogActionRole: Equatable {
    case normal
    case destructive
}

/// App-styled modal confirmation surface used where native alerts are too
/// constrained for Kurn's settings flows.
struct KurnDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let iconSystemName: String
    let iconTint: Color
    let title: String
    let message: String
    let primaryTitle: String
    let primaryRole: KurnDialogActionRole
    let primaryAction: () -> Void
    let secondaryTitle: String
    let secondaryAction: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(0.42)
                            .ignoresSafeArea()

                        dialog
                            .padding(.horizontal, 24)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(100)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isPresented)
    }

    private var dialog: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(iconTint.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconSystemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(iconTint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                dialogButton(
                    title: secondaryTitle,
                    role: .normal,
                    isPrimary: false
                ) {
                    secondaryAction()
                    isPresented = false
                }

                dialogButton(
                    title: primaryTitle,
                    role: primaryRole,
                    isPrimary: true
                ) {
                    primaryAction()
                    isPresented = false
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 12)
        .accessibilityElement(children: .contain)
    }

    private func dialogButton(
        title: String,
        role: KurnDialogActionRole,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let background = isPrimary
            ? (role == .destructive ? Theme.accent : Theme.info)
            : Theme.fill
        let foreground = isPrimary ? Color.white : Theme.textPrimary

        return Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// The standard rounded card surface (#1C1C1E in dark) used across screens.
    func kurnCard(padding: CGFloat = 16, cornerRadius: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Strip the default `List` row chrome (separator + background) so cards sit
    /// directly on the themed background while keeping swipe actions available.
    func clearListRow(insets: EdgeInsets? = nil) -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(insets ?? EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
    }

    func kurnDialog(
        isPresented: Binding<Bool>,
        iconSystemName: String,
        iconTint: Color,
        title: String,
        message: String,
        primaryTitle: String,
        primaryRole: KurnDialogActionRole = .normal,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String,
        secondaryAction: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            KurnDialogModifier(
                isPresented: isPresented,
                iconSystemName: iconSystemName,
                iconTint: iconTint,
                title: title,
                message: message,
                primaryTitle: primaryTitle,
                primaryRole: primaryRole,
                primaryAction: primaryAction,
                secondaryTitle: secondaryTitle,
                secondaryAction: secondaryAction
            )
        )
    }
}
