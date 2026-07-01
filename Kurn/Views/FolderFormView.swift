//
//  FolderFormView.swift
//  Kurn
//
//  Sheet form for creating or renaming a folder. Replaces the inline
//  TextField alert with a proper iOS form that also exposes the icon and
//  colour pickers, so the sidebar isn't stuck with the default look forever.
//  Called with `mode: .create(parent:)` for a new (possibly nested) folder or
//  `.edit(folder)` to rename and restyle an existing one in place.
//

import SwiftData
import SwiftUI

struct FolderFormView: View {
    enum Mode: Equatable {
        case create(parent: Folder?)
        case edit(Folder)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var name: String = ""
    @State private var iconName: String = FolderIconCatalog.default
    @State private var colorHex: String = FolderColorPalette.default
    @State private var initialized = false

    private var navigationTitle: String {
        switch mode {
        case .create:
            return NSLocalizedString("folder.new", comment: "New folder")
        case .edit:
            return NSLocalizedString("folder.rename", comment: "Rename folder")
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("form.title_section", comment: "Title")) {
                    HStack(spacing: 12) {
                        Image(systemName: iconName)
                            .frame(width: 32, height: 32)
                            .background(Color(hex: colorHex).opacity(0.18), in: Circle())
                            .foregroundStyle(Color(hex: colorHex))
                        TextField(
                            NSLocalizedString("folder.name_placeholder", comment: "Folder name"),
                            text: $name
                        )
                    }
                }
                Section(NSLocalizedString("folder.icon", comment: "Icon")) {
                    iconGrid
                }
                Section(NSLocalizedString("folder.color", comment: "Color")) {
                    colorRow
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "Save")) { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: hydrate)
        }
    }

    // MARK: - Subviews

    private var iconGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(FolderIconCatalog.icons, id: \.self) { symbol in
                Button { iconName = symbol } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(iconName == symbol ? Color(hex: colorHex) : Theme.textSecondary)
                        .background(
                            iconName == symbol
                                ? Color(hex: colorHex).opacity(0.18)
                                : Theme.fill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(iconName == symbol ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private var colorRow: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(FolderColorPalette.colors, id: \.self) { hex in
                Button { colorHex = hex } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 30, height: 30)
                        if colorHex == hex {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hex)
                .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Lifecycle

    private func hydrate() {
        guard !initialized else { return }
        initialized = true
        switch mode {
        case .create:
            // Defaults already match `Folder` model defaults via the catalogs.
            break
        case .edit(let folder):
            name = folder.name
            iconName = folder.iconName
            colorHex = folder.colorHex
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .create(let parent):
            let folder = Folder(
                name: trimmed,
                iconName: iconName,
                colorHex: colorHex,
                parent: parent
            )
            modelContext.insert(folder)
        case .edit(let folder):
            folder.name = trimmed
            folder.iconName = iconName
            folder.colorHex = colorHex
        }
        try? modelContext.save()
        dismiss()
    }
}
