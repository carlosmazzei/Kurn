//
//  PrivacyCoverView.swift
//  Kurn
//
//  Opaque cover shown over the app content whenever the scene isn't `.active`,
//  so the OS's app-switcher snapshot (taken during the `.active -> .inactive`
//  transition) captures this instead of live meeting/transcript content.
//

import SwiftUI

struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text("Kurn")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}
