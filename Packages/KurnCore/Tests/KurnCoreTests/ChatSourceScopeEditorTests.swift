import Foundation
import Testing
@testable import KurnCore

struct ChatSourceScopeEditorTests {
    @Test func meetingSelectionIsLockedAndRestorationCannotUnlockIt() {
        let id = UUID(), other = UUID()
        let saved = ChatSourceScope(kind: .tags, selectedIDs: [other], parts: [.summary], partOverrides: [id: [.wiki]])
        var editor = ChatSourceScopeEditor(meetingID: id, scope: saved)
        #expect(editor.mode == .meeting(id))
        #expect(editor.scope.kind == .meetings)
        #expect(editor.scope.selectedIDs == [id])
        #expect(editor.scope.partOverrides.isEmpty)
        #expect(editor.parts(for: id) == [.wiki])
        let changedSelection = editor.setSelection(kind: .library, selectedIDs: [other])
        let changedOverride = editor.setOverride([.transcript], for: other)
        let clearedOverride = editor.clearOverride(for: id)
        #expect(!changedSelection)
        #expect(!changedOverride)
        #expect(!clearedOverride)
        editor.setParts([.transcript, .attachments])
        #expect(editor.parts(for: id) == [.transcript, .attachments])
        #expect(editor.scope.selectedIDs == [id])
        #expect(editor.validation(resolvedMeetingIDs: [id]) == nil)
        editor.setParts([])
        #expect(editor.validation(resolvedMeetingIDs: [id]) == .noParts)
        #expect(editor.validation(resolvedMeetingIDs: [other]) == .noMeetings)
        #expect(ChatSourceScopeEditor(meetingID: id).scope.parts == ChatSourceScope.defaultParts)
    }

    @Test func librarySelectionAndOverridesAreEditable() {
        let id = UUID()
        var editor = ChatSourceScopeEditor()
        #expect(editor.mode == .library)
        #expect(editor.scope.kind == .library)
        for kind in [ChatSourceScope.Kind.meetings, .tags, .folders, .library] {
            let changed = editor.setSelection(kind: kind, selectedIDs: [id])
            #expect(changed)
            #expect(editor.scope.kind == kind)
            #expect(editor.scope.selectedIDs == [id])
        }
        editor.setParts([.summary])
        let changedOverride = editor.setOverride([.transcript, .wiki], for: id)
        #expect(changedOverride)
        #expect(editor.parts(for: id) == [.transcript, .wiki])
        #expect(editor.parts(for: UUID()) == [.summary])
        let cleared = editor.clearOverride(for: id)
        #expect(cleared)
        #expect(editor.parts(for: id) == [.summary])
        let clearedAgain = editor.clearOverride(for: id)
        #expect(clearedAgain)
    }

    @Test func validationUsesResolvedMeetingsAndEffectiveParts() {
        let id = UUID(), other = UUID()
        var editor = ChatSourceScopeEditor(scope: ChatSourceScope(kind: .meetings, selectedIDs: [id], parts: []))
        #expect(editor.validation(resolvedMeetingIDs: []) == .noMeetings)
        #expect(editor.validation(resolvedMeetingIDs: [other]) == .noMeetings)
        #expect(editor.validation(resolvedMeetingIDs: [id, other]) == .noParts)
        editor.setOverride([.summary], for: other)
        #expect(editor.validation(resolvedMeetingIDs: [id, other]) == .noParts)
        editor.setOverride([.transcript], for: id)
        #expect(editor.validation(resolvedMeetingIDs: [id]) == nil)
        editor.setSelection(kind: .tags, selectedIDs: [UUID()])
        #expect(editor.validation(resolvedMeetingIDs: [other]) == nil)
        editor.setParts([.wiki])
        editor.setOverride([], for: other)
        #expect(editor.validation(resolvedMeetingIDs: [other]) == .noParts)
        #expect(editor.validation(resolvedMeetingIDs: [id, other]) == nil)
    }
}
