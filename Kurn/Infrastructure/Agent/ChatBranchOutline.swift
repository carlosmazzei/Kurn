import AgentHarness
import Foundation

/// Every question of a saved conversation as a tree to move around in (NH09): the person's
/// questions in the order they were asked, each indented under the question it followed when that
/// question was followed by more than one, so a linear conversation reads as a flat list and each
/// place a question was asked again opens a level. Run entries are not part of it.
struct ChatBranchOutline: Equatable {
    struct Node: Equatable, Identifiable {
        /// The question's entry; opening it selects the newest leaf of its branch.
        let id: String
        let text: String
        let depth: Int
        /// Whether the question is on the branch shown.
        let isShown: Bool
        let label: String?
    }

    let nodes: [Node]

    /// Whether there is more than one branch to show.
    var hasBranches: Bool { nodes.contains { $0.depth > 0 } }

    init(nodes: [Node] = []) { self.nodes = nodes }

    init(tree: AgentSessionTree) {
        var questions: [String: (entry: AgentSessionEntry, text: String)] = [:]
        for entry in tree.entries where !AgentSessionTree.isRunEntry(entry) {
            if case .message(.content(let message)) = entry.payload, message.role == .user {
                questions[entry.id] = (entry, message.text)
            }
        }
        // The question each question followed: its nearest question ancestor.
        func parent(of entry: AgentSessionEntry) -> String? {
            var cursor = entry.parentID
            while let id = cursor, let ancestor = tree.entry(id) {
                if questions[id] != nil { return id }
                cursor = ancestor.parentID
            }
            return nil
        }
        var children: [String?: [AgentSessionEntry]] = [:]
        for (_, question) in questions { children[parent(of: question.entry), default: []].append(question.entry) }
        let shown = Set(tree.activePath.map(\.id))
        let labels = tree.labels
        var nodes: [Node] = []
        func visit(_ parentID: String?, depth: Int) {
            let ordered = (children[parentID] ?? []).sorted { $0.ordinal < $1.ordinal }
            let childDepth = ordered.count > 1 ? depth + 1 : depth
            for entry in ordered {
                nodes.append(Node(id: entry.id, text: questions[entry.id]?.text ?? "", depth: childDepth,
                                  isShown: shown.contains(entry.id), label: labels[entry.id]))
                visit(entry.id, depth: childDepth)
            }
        }
        visit(nil, depth: 0)
        self.nodes = nodes
    }
}
