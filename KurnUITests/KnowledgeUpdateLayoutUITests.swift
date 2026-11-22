import XCTest

@MainActor
final class KnowledgeUpdateLayoutUITests: XCTestCase {
    func testUpdateKnowledgeKeepsTheFactsOnScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["UI-Testing-Screenshots", "UI-Testing-DisableAnimations", "UI-Testing-KnowledgeFixture",
            "-settings.knowledgeEnabled", "YES", "-settings.semanticSearchEnabled", "NO",
            "-settings.meetingsSortOrder", "dateNewest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = app.buttons["meetingCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.buttons["tab.knowledge"].waitForExistence(timeout: 10))
        app.buttons["tab.knowledge"].tap()
        let update = app.buttons["knowledge.refresh"].firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 10))
        update.tap()
        var sawPlaceholder = false
        for _ in 0..<12 {
            if app.staticTexts["Loading contributions…"].exists || app.descendants(matching: .any)["knowledge.header"].firstMatch.exists == false {
                sawPlaceholder = true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(sawPlaceholder, "the facts header disappeared while updating")
    }
}
