//
//  SummaryCompareView.swift
//  Kurn
//
//  "Compare side by side" from the summary pill menu — for now a paged view
//  that swipes between the meeting's summaries. P2b builds the real
//  comparison screen; the entry point and presentation are already wired.
//

import SwiftUI

struct SummaryCompareView: View {
    /// Newest first — same order as the summary pill menu and page dots.
    let summaries: [Summary]
    let meeting: Meeting

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView {
                ForEach(summaries) { summary in
                    ScrollView {
                        SummaryView(summary: summary)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                    }
                }
            }
            .tabViewStyle(.page)
            .navigationTitle(NSLocalizedString("detail.summary.compare", comment: "Compare side by side"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
    }
}
