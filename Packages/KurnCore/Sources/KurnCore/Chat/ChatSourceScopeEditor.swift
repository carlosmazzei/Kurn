import Foundation

public struct ChatSourceScopeEditor: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case meeting(UUID), library }
    public enum Validation: String, Codable, Sendable { case noMeetings, noParts }

    public let mode: Mode
    public private(set) var scope: ChatSourceScope

    public init(meetingID: UUID? = nil, scope: ChatSourceScope? = nil) {
        if let meetingID {
            mode = .meeting(meetingID)
            self.scope = ChatSourceScope(kind: .meetings, selectedIDs: [meetingID],
                                         parts: scope?.parts(for: meetingID) ?? ChatSourceScope.defaultParts)
        } else {
            mode = .library
            self.scope = scope ?? ChatSourceScope(kind: .library)
        }
    }

    @discardableResult public mutating func setSelection(kind: ChatSourceScope.Kind, selectedIDs: Set<UUID>) -> Bool {
        guard mode == .library else { return false }
        scope.kind = kind
        scope.selectedIDs = selectedIDs
        return true
    }

    public mutating func setParts(_ parts: Set<ChatSourcePart>) { scope.parts = parts }

    @discardableResult public mutating func setOverride(_ parts: Set<ChatSourcePart>, for meetingID: UUID) -> Bool {
        guard mode == .library else { return false }
        scope.partOverrides[meetingID] = parts
        return true
    }

    @discardableResult public mutating func clearOverride(for meetingID: UUID) -> Bool {
        guard mode == .library else { return false }
        scope.partOverrides.removeValue(forKey: meetingID)
        return true
    }

    public func parts(for meetingID: UUID) -> Set<ChatSourcePart> { scope.parts(for: meetingID) }

    public func validation(resolvedMeetingIDs: Set<UUID>) -> Validation? {
        let ids = scope.kind == .meetings ? resolvedMeetingIDs.intersection(scope.selectedIDs) : resolvedMeetingIDs
        guard !ids.isEmpty else { return .noMeetings }
        return ids.contains { !scope.parts(for: $0).isEmpty } ? nil : .noParts
    }
}
