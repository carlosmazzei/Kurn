import Testing
@testable import KurnCore

@Suite struct ChatTimestampCitationsTests {
    @Test func parsesBothFormatsInOrderWithoutDuplicates() {
        let text = "See [1:12] then [0:05] and later [1:02:03]; repeat [1:12]."
        #expect(ChatTimestampCitations.times(in: text) == [72, 5, 3_723])
    }

    @Test func ignoresTextWithoutCitations() {
        #expect(ChatTimestampCitations.times(in: "No [citations] here, [123:45] or 1:02.").isEmpty)
        #expect(ChatTimestampCitations.times(in: "").isEmpty)
    }
}
