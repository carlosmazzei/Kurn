import AgentHarness
import Foundation

/// What the chat shows of a saved conversation's tree (NH09), read from `AgentSessionTree`: the
/// entry behind each shown turn, the other versions of a question asked again in the same place,
/// the labels on turns, and recorded usage over every branch versus the branch shown.
struct ChatBranchPresentation: Equatable {
    /// The versions of a question, oldest first, and which one is shown.
    struct Alternatives: Equatable {
        let entryIDs: [String]
        let index: Int
        var count: Int { entryIDs.count }
        /// The version `offset` away from the shown one, if there is one.
        func entryID(offset: Int) -> String? {
            entryIDs.indices.contains(index + offset) ? entryIDs[index + offset] : nil
        }
    }

    /// The entry behind each shown turn, by turn ID.
    private(set) var entryIDs: [UUID: String] = [:]
    /// Questions asked more than once in the same place, by the shown turn's ID.
    private(set) var alternatives: [UUID: Alternatives] = [:]
    private(set) var labels: [UUID: String] = [:]
    /// Every question of the conversation as a tree (`ChatBranchOutline`).
    private(set) var outline = ChatBranchOutline()
    /// Shown turns later runs leave out of what they replay (`AgentContextEdit`).
    private(set) var leftOut: Set<UUID> = []
    /// Usage recorded by every branch's runs, and by the runs of the branch shown.
    private(set) var sessionUsage: AgentUsage?
    private(set) var branchUsage: AgentUsage?

    init() {}

    init(tree: AgentSessionTree) {
        let entryLabels = tree.labels
        for entry in tree.activePath {
            guard case .message(.content(let message)) = entry.payload, let turnID = UUID(uuidString: message.id) else { continue }
            entryIDs[turnID] = entry.id
            if let label = entryLabels[entry.id] { labels[turnID] = label }
            guard message.role == .user else { continue }
            let versions = tree.alternatives(of: entry.id)
            if versions.count > 1, let index = versions.firstIndex(of: entry.id) {
                alternatives[turnID] = Alternatives(entryIDs: versions, index: index)
            }
        }
        leftOut = Set(AgentContextEdit.excluded(by: AgentContextEdit.all(in: tree.entries)).compactMap(UUID.init(uuidString:)))
            .intersection(entryIDs.keys)
        outline = ChatBranchOutline(tree: tree)
        sessionUsage = tree.usage(.session)
        branchUsage = tree.usage(.activePath)
    }

    /// Recorded tokens of the branch shown and of every branch, when other branches recorded some.
    var usageSummary: String? {
        guard let session = sessionUsage, session != branchUsage else { return nil }
        let branch = branchUsage.map { $0.inputTokens + $0.outputTokens } ?? 0
        return String(format: NSLocalizedString("chat.branch.usage", comment: "Branch and session token totals"),
                      branch, session.inputTokens + session.outputTokens)
    }
}
