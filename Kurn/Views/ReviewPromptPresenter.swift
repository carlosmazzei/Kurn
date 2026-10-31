//
//  ReviewPromptPresenter.swift
//  Kurn
//
//  Shows the system App Store rating prompt when `ReviewPromptCoordinator`
//  says one is due. Every decision lives in the coordinator; this only turns
//  a changed `requestToken` into `RequestReviewAction`, which iOS may still
//  decline to show (it caps the prompt at three times a year).
//

import StoreKit
import SwiftUI

extension View {
    /// Attaches the rating prompt for the environment's
    /// `ReviewPromptCoordinator`.
    func reviewPromptPresenter() -> some View {
        modifier(ReviewPromptPresenter())
    }
}

private struct ReviewPromptPresenter: ViewModifier {
    @Environment(ReviewPromptCoordinator.self) private var reviewPrompt
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content.onChange(of: reviewPrompt.requestToken) {
            if reviewPrompt.consumePendingRequest() {
                requestReview()
            }
        }
    }
}
