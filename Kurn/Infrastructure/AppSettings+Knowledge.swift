import Foundation
import KurnCore

extension AppSettings {
    /// The Knowledge Engine's feature flag (CLAUDE.md, "Knowledge Engine
    /// decisions"). **Off by default and separate from `wikiEnabled`**:
    /// consenting to a per-meeting wiki never authorizes compiling knowledge
    /// across meetings. While it is off, `KnowledgePolicyEvaluator` refuses
    /// every Knowledge operation, local or remote.
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

    /// Whether the Knowledge browser may write an export bundle (K6.2). Off by default; it
    /// becomes the local policy's `exportAllowed`, so `KnowledgePolicyEvaluator` refuses
    /// `.export` while it is off.
    var knowledgeExportEnabled: Bool {
        get {
            access(keyPath: \.knowledgeExportEnabled)
            return defaults.bool(forKey: Keys.knowledgeExportEnabled)
        }
        set {
            withMutation(keyPath: \.knowledgeExportEnabled) {
                defaults.set(newValue, forKey: Keys.knowledgeExportEnabled)
            }
        }
    }

    /// Missing preferences use safe defaults. Corrupt/future preferences stay
    /// unreadable so an upgrade never silently widens the selected source ACL.
    var knowledgeControls: KnowledgeControls? {
        access(keyPath: \.knowledgeControls)
        guard let stored = defaults.object(forKey: "settings.knowledgeControls.v1") else { return KnowledgeControls() }
        guard let data = stored as? Data else { return nil }
        return try? KnowledgeControls.decode(data)
    }

    func saveKnowledgeControls(_ requested: KnowledgeControls) throws {
        guard let current = knowledgeControls, current.revision == requested.revision,
              current.generation == requested.generation else { throw KnowledgeControlsError.staleControls }
        var next = try requested.validated()
        next.revision += 1
        let data = try next.encoded()
        withMutation(keyPath: \.knowledgeControls) { defaults.set(data, forKey: "settings.knowledgeControls.v1") }
    }

    func resetKnowledgeControls() throws {
        knowledgeEnabled = false
        knowledgeExportEnabled = false
        var controls = KnowledgeControls()
        controls.generation = UUID().uuidString
        let data = try controls.encoded()
        withMutation(keyPath: \.knowledgeControls) { defaults.set(data, forKey: "settings.knowledgeControls.v1") }
    }

    var knowledgeProvider: AIProvider? {
        guard let controls = knowledgeControls else { return nil }
        return providers.first { $0.id == controls.providerID }
    }
}
