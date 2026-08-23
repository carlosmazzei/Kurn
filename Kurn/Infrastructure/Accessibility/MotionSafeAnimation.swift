//
//  MotionSafeAnimation.swift
//  Kurn
//
//  A single reusable spot to honor `accessibilityReduceMotion` instead of
//  repeating `@Environment(\.accessibilityReduceMotion)` at every animation
//  call site. Covers the common case (`.animation(_:value:)`); a `repeatForever`
//  loop (e.g. a pulsing dot) needs its own `onAppear` guard instead, since there
//  is no animation to swap out — the loop must never start.
//

import SwiftUI

private struct ReduceMotionAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Drop-in replacement for `.animation(_:value:)` that disables the
    /// animation (applying the end state immediately) when the user has
    /// Reduce Motion enabled.
    func kurnAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReduceMotionAnimation(animation: animation, value: value))
    }
}
