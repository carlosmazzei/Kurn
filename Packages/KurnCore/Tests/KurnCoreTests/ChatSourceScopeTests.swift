import Foundation
import Testing
@testable import KurnCore

@Suite struct ChatSourceScopeTests {
    @Test func globalSelectionAndOverridesRoundTrip() throws {
        let first = UUID(), second = UUID(), other = UUID()
        let scope = ChatSourceScope(kind: .meetings, selectedIDs: [first, second], parts: [.summary],
                                    partOverrides: [first: [.wiki, .attachments], second: []])
        #expect(scope.parts(for: first) == [.wiki, .attachments])
        #expect(scope.parts(for: second).isEmpty)
        #expect(scope.parts(for: other) == [.summary])
        let data = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(ChatSourceScope.self, from: data) == scope)
        #expect(!String(decoding: data, as: UTF8.self).contains("includeWikis"))
        #expect(Set(ChatSourcePart.allCases) == [.transcript, .summary, .wiki, .attachments, .knowledge])
    }

    @Test func knowledgeIsAPartAndLegacyScopesKeepOfferingIt() throws {
        let kept = UUID(), excluded = UUID()
        let without = ChatSourceScope(kind: .meetings, selectedIDs: [kept], parts: [.transcript], partOverrides: [kept: [.summary]])
        #expect(try JSONDecoder().decode(ChatSourceScope.self, from: JSONEncoder().encode(without)) == without)
        let saved = ChatSourceScope(kind: .meetings, parts: [.transcript], partOverrides: [kept: [.summary], excluded: []])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["knowledgeSelectable"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatSourceScope.self, from: legacy)
        #expect(decoded.parts == [.transcript, .knowledge])
        #expect(decoded.parts(for: kept) == [.summary, .knowledge])
        #expect(decoded.parts(for: excluded).isEmpty)
        let hidden = ChatSourcePresentation.effectiveScope(decoded, wikiEnabled: true, knowledgeEnabled: false)
        #expect(hidden.parts == [.transcript] && hidden.parts(for: kept) == [.summary])
    }

    @Test(arguments: [true, false]) func legacyDecode(wiki: Bool) throws {
        let id = UUID()
        let payload = "{\"kind\":\"folders\",\"selectedIDs\":[\"\(id)\"],\"includeWikis\":\(wiki)}"
        let scope = try JSONDecoder().decode(ChatSourceScope.self, from: Data(payload.utf8))
        #expect(scope.kind == .folders)
        #expect(scope.selectedIDs == [id])
        #expect(scope.parts == (wiki ? Set(ChatSourcePart.allCases) : ChatSourceScope.defaultParts))
        #expect(scope.partOverrides.isEmpty)
    }

    @Test func missingFieldsAndExplicitEmptyParts() throws {
        let decoder = JSONDecoder()
        let defaults = try decoder.decode(ChatSourceScope.self, from: Data("{\"kind\":\"library\"}".utf8))
        #expect(defaults.parts == ChatSourceScope.defaultParts)
        #expect(defaults.selectedIDs.isEmpty)
        let explicit = try decoder.decode(ChatSourceScope.self,
            from: Data("{\"kind\":\"library\",\"parts\":[],\"includeWikis\":true}".utf8))
        #expect(explicit.parts.isEmpty)
    }

    @Test func legacyAPIOnlyChangesGlobalSelection() {
        let id = UUID()
        var scope = ChatSourceScope(kind: .tags, includeWikis: true)
        #expect(scope.includeWikis)
        scope.partOverrides[id] = [.wiki]
        scope.includeWikis = false
        #expect(!scope.parts.contains(.wiki))
        #expect(scope.parts(for: id) == [.wiki])
        scope.includeWikis = true
        #expect(scope.parts == Set(ChatSourcePart.allCases))
        #expect(ChatSourceScope(kind: .library, includeWikis: false).parts == ChatSourceScope.defaultParts)
    }

    @Test(arguments: ["{}", "{\"kind\":\"bad\"}", "{\"kind\":\"library\",\"parts\":[\"secret\"]}",
                      "{\"kind\":\"library\",\"includeWikis\":\"yes\"}"])
    func invalidPayloads(payload: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ChatSourceScope.self, from: Data(payload.utf8)) }
    }
}
