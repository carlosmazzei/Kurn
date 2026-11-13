import CoreGraphics
import Testing
@testable import Kurn

/// NH08: a new turn moves the reader only when they are at the end or just asked.
struct ChatScrollFollowingTests {
    @Test func aReaderAtTheEndFollowsNewTurns() {
        var following = ChatScrollFollowing()
        #expect(following.follows(newTurnIsOwnQuestion: false))
        following.observe(contentOffsetY: 1_000, visibleHeight: 600, contentHeight: 1_650)
        #expect(following.isAtEnd)
        #expect(following.follows(newTurnIsOwnQuestion: false))
    }

    @Test func aReaderOfOlderMessagesStaysWhereTheyAreUnlessTheyAsk() {
        var following = ChatScrollFollowing()
        following.observe(contentOffsetY: 200, visibleHeight: 600, contentHeight: 2_000)
        #expect(!following.isAtEnd)
        #expect(!following.follows(newTurnIsOwnQuestion: false))
        #expect(following.follows(newTurnIsOwnQuestion: true))
    }
}
