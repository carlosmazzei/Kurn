import Foundation
import Testing
@testable import KurnCore

struct KnowledgeControlsTests {
    @Test func defaultsAreLocalAndNeverStartAutomaticCompilation() throws {
        let controls = KnowledgeControls()
        #expect(!controls.automaticCompilation && !controls.isPaused)
        #expect(controls.providerID == "apple-on-device")
        #expect(controls.allows(UUID()))
        #expect(try KnowledgeControls.decode(controls.encoded()) == controls)
    }

    @Test func explicitEmptyScopeAndExclusionsNeverWidenSelection() throws {
        let allowed = UUID(), excluded = UUID()
        var controls = KnowledgeControls()
        controls.includedMeetingIDs = []
        #expect(!controls.allows(allowed))
        controls.includedMeetingIDs = [allowed, excluded]
        controls.excludedMeetingIDs = [excluded]
        #expect(controls.allows(allowed) && !controls.allows(excluded) && !controls.allows(UUID()))
        #expect(try KnowledgeControls.decode(controls.encoded()) == controls)
    }

    @Test func futureCorruptAndOversizedControlsAreRefused() throws {
        var controls = KnowledgeControls()
        controls.version = 2
        #expect(throws: KnowledgeControlsError.unsupportedVersion) { try controls.encoded() }
        #expect(throws: (any Error).self) { try KnowledgeControls.decode(Data("{}".utf8)) }
        #expect(throws: KnowledgeControlsError.invalidControls) { try KnowledgeControls.decode(Data(repeating: 0, count: 1_048_577)) }
    }

    @Test func invalidRevisionProviderAndResetGenerationAreRefused() {
        var controls = KnowledgeControls()
        controls.revision = Int.max
        #expect(throws: KnowledgeControlsError.invalidControls) { try controls.encoded() }
        controls.revision = 1; controls.providerID = ""
        #expect(throws: KnowledgeControlsError.invalidControls) { try controls.encoded() }
        controls.providerID = "apple-on-device"; controls.generation = "invalid"
        #expect(throws: KnowledgeControlsError.invalidControls) { try controls.encoded() }
    }

    @Test func scopeEditingPreservesExplicitIntentAndExclusions() {
        let id = UUID()
        var controls = KnowledgeControls()
        controls.toggleMeeting(id)
        #expect(controls.includedMeetingIDs == nil && controls.excludedMeetingIDs == [id])
        controls.setAllMeetings(false)
        #expect(controls.includedMeetingIDs == [] && !controls.allows(id))
        controls.toggleMeeting(id)
        #expect(controls.includedMeetingIDs == [id] && controls.excludedMeetingIDs.isEmpty)
        controls.toggleMeeting(id)
        #expect(controls.includedMeetingIDs == [])
        controls.setAllMeetings(true)
        #expect(controls.includedMeetingIDs == nil && controls.allows(id))
    }
}
