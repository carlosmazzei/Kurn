import Foundation

extension AppSettings {
    /// The Knowledge Engine's feature flag (CLAUDE.md, "Knowledge Engine
    /// decisions"). **Off by default and separate from `wikiEnabled`**:
    /// consenting to a per-meeting wiki never authorizes compiling knowledge
    /// across meetings. While it is off, `KnowledgePolicyEvaluator` refuses
    /// every Knowledge operation, local or remote. It has no Settings row yet;
    /// the Knowledge settings screen adds one.
    ///
    /// Stored in `UserDefaults` like the other toggles, and made observable by
    /// hand because an extension cannot hold the macro-generated storage.
    var knowledgeEnabled: Bool {
        get {
            access(keyPath: \.knowledgeEnabled)
            return defaults.bool(forKey: Keys.knowledgeEnabled)
        }
        set {
            withMutation(keyPath: \.knowledgeEnabled) {
                defaults.set(newValue, forKey: Keys.knowledgeEnabled)
            }
        }
    }
}
