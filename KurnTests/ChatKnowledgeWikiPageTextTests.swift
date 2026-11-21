import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ChatKnowledgeWikiPageTextTests {
    @Test func aNarrativeParagraphListsItsNumberTextAndCitedAssertions() {
        let first = UUID(), second = UUID()
        let paragraph = KnowledgeWikiNarrative.Paragraph(text: "The portal is\nblocked by the platform team.",
                                                         assertionIDs: [first, second])
        let rendered = ChatKnowledgeToolText.paragraph(paragraph, index: 2)
        #expect(rendered.text == "- 2 | The portal is blocked by the platform team. | \(first.uuidString), \(second.uuidString)")
        #expect(rendered.omittedScalars == 0)
    }

    @Test func aLongParagraphIsClippedAndCountsWhatItOmits() {
        let paragraph = KnowledgeWikiNarrative.Paragraph(text: String(repeating: "a", count: 2_100), assertionIDs: [UUID()])
        #expect(ChatKnowledgeToolText.paragraph(paragraph, index: 1).omittedScalars > 0)
    }
}
