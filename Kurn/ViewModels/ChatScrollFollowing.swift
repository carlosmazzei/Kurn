import CoreGraphics

/// When the chat follows its newest turn (NH08): only while the reader is at the end of the
/// conversation, or when the newest turn is a question they just sent. A turn that arrives while
/// they read older messages — a reply, or queued input the run took in — never moves them.
struct ChatScrollFollowing: Equatable {
    /// How close to the end still counts as reading the end, in points.
    static let tolerance: CGFloat = 80

    private(set) var isAtEnd = true

    /// Updates where the reader is from the scroll view's geometry.
    mutating func observe(contentOffsetY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat) {
        isAtEnd = contentOffsetY + visibleHeight >= contentHeight - Self.tolerance
    }

    /// Whether a newly added turn should be scrolled into view.
    func follows(newTurnIsOwnQuestion: Bool) -> Bool { isAtEnd || newTurnIsOwnQuestion }
}
