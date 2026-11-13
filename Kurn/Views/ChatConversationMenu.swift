import SwiftUI

/// The open conversation's actions (NH09/NH10): duplicate it, export it whole as an archive or the
/// branch shown to read (Markdown, Word or HTML), and import an archive as a new conversation.
struct ChatConversationMenu: View {
    let vm: MeetingChatViewModel
    @Binding var shareItem: ShareItem?
    @Binding var showingImporter: Bool

    var body: some View {
        Menu {
            Button {
                vm.duplicateConversation()
            } label: {
                Label(NSLocalizedString("chat.branch.duplicate", comment: "Duplicate this conversation"), systemImage: "plus.square.on.square")
            }
            .disabled(!vm.canChangeBranch)
            Menu {
                ForEach(DocumentExport.formats, id: \.self) { format in
                    Button(format.title) {
                        if let url = vm.exportReadable(as: format) { shareItem = ShareItem(urls: [url]) }
                    }
                }
            } label: {
                Label(NSLocalizedString("chat.archive.export_as", comment: "Export the conversation shown in a reading format"),
                      systemImage: "doc.text")
            }
            .disabled(vm.isResponding || vm.turns.isEmpty)
            Button {
                if let url = vm.exportArchive() { shareItem = ShareItem(urls: [url]) }
            } label: {
                Label(NSLocalizedString("chat.archive.export", comment: "Export the whole conversation as an archive"),
                      systemImage: "square.and.arrow.up")
            }
            .disabled(!vm.canChangeBranch)
            Button {
                showingImporter = true
            } label: {
                Label(NSLocalizedString("chat.archive.import", comment: "Import a conversation archive"), systemImage: "square.and.arrow.down")
            }
            .disabled(vm.isResponding)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(NSLocalizedString("chat.conversation.more", comment: "Conversation actions"))
        .accessibilityIdentifier("chat.conversation.more")
    }
}
