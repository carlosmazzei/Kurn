import Testing
@testable import AgentHarness

struct AgentTextPageTests {
    @Test(arguments: ["abc", "中文🙂e\u{301}"])
    func continuationRecoversEveryScalarWithinBothBounds(unit: String) throws {
        let text = String(repeating: unit, count: 1_000)
        var recovered = ""
        var offset = 0
        repeat {
            let page = try AgentTextPage(text, offset: offset, maxScalars: 100, maxBytes: 127)
            #expect(page.text.utf8.count <= 127)
            #expect(page.returnedScalars <= 100)
            #expect(page.nextOffset > offset)
            #expect(page.metrics[.deferredScalars] == text.unicodeScalars.count - page.nextOffset)
            recovered += page.text
            offset = page.nextOffset
        } while offset < text.unicodeScalars.count
        #expect(recovered == text)
    }

    @Test func zeroProgressFailsAndReadingPastTheEndRemainsEmpty() throws {
        #expect(throws: AgentTextPage.NoProgress.self) { try AgentTextPage("🙂", offset: 0, maxBytes: 3) }
        #expect(throws: AgentTextPage.NoProgress.self) { try AgentTextPage("text", offset: 0, maxScalars: 0) }
        let end = try AgentTextPage("text", offset: 50)
        #expect(end.text.isEmpty)
        #expect(!end.hasMore)
    }
}
