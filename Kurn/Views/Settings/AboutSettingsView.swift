//
//  AboutSettingsView.swift
//  Kurn
//
//  Version, third-party acknowledgements, and the sponsorship link.
//

import SwiftUI

struct AboutSettingsView: View {

    /// Marketing version + build, read the same way `DiagnosticsSubscriber` does.
    private var versionText: String {
        let bundle = Bundle.main
        let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(marketing) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(
                    NSLocalizedString("settings.version", comment: "Version"),
                    value: versionText
                )
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Label(
                        NSLocalizedString("settings.acknowledgements", comment: "Acknowledgements"),
                        systemImage: "doc.text"
                    )
                }
                Link(destination: URL(string: "https://github.com/sponsors/carlosmazzei")!) {
                    Label(
                        NSLocalizedString("settings.sponsor", comment: "Sponsor Kurn"),
                        systemImage: "heart"
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.about", comment: "About"))
    }
}
