import KurnCore
import SwiftData
import SwiftUI
import UIKit

struct ChatArtifactCard: View {
    let reference: ChatArtifactReference
    let artifact: ChatDocumentArtifact
    let session: ChatSession
    @Environment(\.modelContext) private var context
    @Query private var documents: [GeneratedDocument]
    @State private var showingPreview = false
    @State private var shareItem: ShareItem?
    @State private var error: AppError?

    init(reference: ChatArtifactReference, artifact: ChatDocumentArtifact, session: ChatSession) {
        self.reference = reference
        self.artifact = artifact
        self.session = session
        let sessionID = session.id
        let artifactID = artifact.id
        _documents = Query(filter: #Predicate<GeneratedDocument> {
            $0.sourceChatSessionID == sessionID && $0.sourceArtifactID == artifactID
        })
    }

    private var action: ChatArtifactStore.ArtifactSaveAction {
        ChatArtifactStore.action(artifact: artifact, saved: documents.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showingPreview = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Label(artifact.title, systemImage: "doc.text")
                        .font(.headline)
                    Text(ChatArtifactPresentation.version(reference, latest: artifact,
                                                         localize: { NSLocalizedString($0, comment: "Artifact version") }))
                        .font(.caption)
                    MarkdownText(ChatArtifactPresentation.preview(artifact))
                        .font(.subheadline)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(artifact.title + ", " + NSLocalizedString("chat.artifact.preview", comment: "Preview"))
            .accessibilityIdentifier("chat.artifact.\(artifact.id.uuidString)")
            actions
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.separator, lineWidth: 1))
        .sheet(isPresented: $showingPreview) {
            NavigationStack {
                ScrollView {
                    MarkdownText(artifact.markdown)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .navigationTitle(artifact.title)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { actions.padding().background(.bar) }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("common.done", comment: "Done")) { showingPreview = false }
                            .accessibilityIdentifier("chat.artifact.preview.done")
                    }
                }
            }
            .sheet(item: $shareItem) { ActivityView(items: $0.urls) }
            .errorAlert($error)
        }
        .sheet(item: Binding(get: { showingPreview ? nil : shareItem }, set: { shareItem = $0 })) {
            ActivityView(items: $0.urls)
        }
        .errorAlert($error)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                do { _ = try ChatArtifactStore(context: context).save(artifactID: artifact.id, session: session) }
                catch { self.error = (error as? AppError) ?? .persistenceFailed(error.localizedDescription) }
            } label: {
                Label(NSLocalizedString(action.rawValue, comment: "Save artifact"),
                      systemImage: action == .saved ? "checkmark.circle" : "square.and.arrow.down")
            }
            .disabled(action == .saved)
            .accessibilityIdentifier("chat.artifact.save.\(artifact.id.uuidString)")
            HStack(spacing: 20) {
                Menu {
                    ForEach(DocumentExport.formats, id: \.self) { format in
                        Button(format.title) {
                            do { shareItem = ShareItem(urls: [try DocumentExport.file(title: artifact.title, markdown: artifact.markdown, format: format)]) }
                            catch { self.error = .persistenceFailed(error.localizedDescription) }
                        }
                    }
                } label: {
                    Label(NSLocalizedString("chat.artifact.export", comment: "Export"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("chat.artifact.export.\(artifact.id.uuidString)")
                Button { UIPasteboard.general.string = artifact.markdown } label: {
                    Label(NSLocalizedString("chat.artifact.copy", comment: "Copy Markdown"), systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("chat.artifact.copy.\(artifact.id.uuidString)")
            }
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
    }
}
