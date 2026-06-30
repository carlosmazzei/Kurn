//
//  AcknowledgementsView.swift
//  Kurn
//
//  Open-source attribution screen reached from Settings → Acknowledgements.
//  Mirrors THIRD_PARTY_NOTICES.md so the license credits required by the
//  bundled FluidAudio package and the on-demand CoreML models are also
//  available inside the app.
//

import SwiftUI

struct AcknowledgementsView: View {
    /// A single credited component. `name`/`license` are proper names and
    /// license identifiers, so they stay verbatim rather than localized.
    private struct Credit: Identifiable {
        let name: String
        let license: String
        let urlString: String
        var id: String { name }
        var url: URL? { URL(string: urlString) }
    }

    private let packages: [Credit] = [
        Credit(
            name: "FluidAudio",
            license: "Apache License 2.0",
            urlString: "https://github.com/FluidInference/FluidAudio"
        )
    ]

    private let models: [Credit] = [
        Credit(
            name: "NVIDIA Parakeet TDT (ASR)",
            license: "NVIDIA / open-source model license",
            urlString: "https://github.com/NVIDIA/NeMo"
        ),
        Credit(
            name: "pyannote-audio (diarization)",
            license: "MIT License",
            urlString: "https://github.com/pyannote/pyannote-audio"
        ),
        Credit(
            name: "WeSpeaker (diarization)",
            license: "Apache License 2.0",
            urlString: "https://github.com/wenet-e2e/wespeaker"
        ),
        Credit(
            name: "NVIDIA Sortformer (diarization)",
            license: "NVIDIA Open Model License",
            urlString: "https://github.com/NVIDIA/NeMo"
        ),
        Credit(
            name: "Silero VAD",
            license: "MIT License",
            urlString: "https://github.com/snakers4/silero-vad"
        )
    ]

    var body: some View {
        Form {
            Section {
                Text(NSLocalizedString("ack.intro", comment: "Acknowledgements intro"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            Section(NSLocalizedString("ack.packages", comment: "Swift packages")) {
                ForEach(packages) { creditRow($0) }
            }

            Section {
                ForEach(models) { creditRow($0) }
            } header: {
                Text(NSLocalizedString("ack.models", comment: "Machine-learning models"))
            } footer: {
                Text(NSLocalizedString("ack.footer", comment: "Acknowledgements footer"))
            }
        }
        .navigationTitle(NSLocalizedString("settings.acknowledgements", comment: "Acknowledgements"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func creditRow(_ credit: Credit) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(credit.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(credit.license)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }

        if let url = credit.url {
            Link(destination: url) {
                HStack {
                    content
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } else {
            content
        }
    }
}
