import KurnCore
import SwiftUI

extension View {
    /// Presents the destructive change a chat run waits on, for the person to allow or refuse.
    func chatChangeConfirmation(_ confirmation: ChatChangeConfirmation) -> some View {
        // Only the sheet's own buttons answer, so a dismissal can never answer a later request.
        sheet(item: Binding(get: { confirmation.pending }, set: { _ in })) { request in
            ChatChangeConfirmationSheet(request: request,
                                        answer: { confirmation.answer($0, to: request.id) })
        }
    }
}

/// "Replace this document?": what the document is now called, the title it would get and the text
/// that would replace its body. Replacing keeps the earlier version, which the card can restore.
struct ChatChangeConfirmationSheet: View {
    let request: ChatChangeRequest
    let answer: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(NSLocalizedString("chat.confirm.replace.message", comment: "What replacing a document does"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let newTitle = request.newTitle, request.document != nil {
                        Label(String(format: NSLocalizedString("chat.confirm.replace.new_title", comment: "New title"), newTitle),
                              systemImage: "character.cursor.ibeam")
                            .font(.subheadline)
                    }
                    MarkdownText(request.markdown)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("chat.confirm.replace.preview")
                }
                .padding(20)
            }
            .navigationTitle(String(format: NSLocalizedString("chat.confirm.replace.title", comment: "Replace document?"),
                                    request.documentTitle))
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("chat.confirm.replace.deny", comment: "Don't replace")) { answer(false) }
                        .accessibilityIdentifier("chat.confirm.replace.deny")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("chat.confirm.replace.allow", comment: "Replace")) { answer(true) }
                        .inkProminent()
                        .accessibilityIdentifier("chat.confirm.replace.allow")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}
