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
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
        }
    }
}
