//
//  SecurityCoverState.swift
//  KurnCore
//
//  What the app's security cover should be showing, derived from the scene
//  phase and the recordings gate. Split out as a pure value type because the
//  cover itself lives in a `UIWindow` (see `SecurityCoverWindow`) and window
//  layering can't be exercised in a unit test — the decision of *what* to show
//  can, and that is where the behaviour actually lives.
//

/// The three things the cover window can be doing. The uncovered case is named
/// `hidden` rather than `none` so it never has to be disambiguated from
/// `Optional.none` at a call site.
public enum SecurityCoverState: Equatable {
    /// Nothing covered; the window is hidden so it captures no touches.
    case hidden
    /// Opaque placeholder with no controls, so the OS app-switcher snapshot
    /// captures this instead of live meeting content.
    case privacy
    /// The authentication screen. Interactive: the user has to be able to tap
    /// Unlock, and to type in the Settings escape hatch it presents.
    case locked
}

public extension SecurityCoverState {
    /// Resolve the cover from the two inputs that drive it.
    ///
    /// A non-active phase always wins. It is the transition during which the
    /// snapshot is taken, and the lock screen's controls are useless in it —
    /// so even a locked app shows the neutral privacy cover while inactive,
    /// then flips to `.locked` once it is foregrounded again.
    static func resolve(
        phase: AppLifecyclePhase,
        requireAuth: Bool,
        isUnlocked: Bool
    ) -> SecurityCoverState {
        guard phase == .active else { return .privacy }
        return requireAuth && !isUnlocked ? .locked : .hidden
    }

    /// Whether the cover window should be on screen at all.
    var isCovering: Bool { self != .hidden }

    /// Whether the cover needs to be the key window. Only the lock screen does:
    /// it has buttons, and the Settings escape hatch it presents contains text
    /// fields that cannot receive keyboard input from a non-key window. The
    /// privacy cover deliberately does not take key status, so a transient
    /// interruption doesn't disturb whatever the app was doing.
    var needsKeyWindow: Bool { self == .locked }
}
