//
//  ActivityView.swift
//  Kurn
//
//  UIActivityViewController bridge for sharing the exported Markdown file.
//

import SwiftUI
import UIKit

/// Wraps a URL so it can drive `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let fileURLs = items.compactMap { $0 as? URL }.filter { $0.isFileURL }
        controller.completionWithItemsHandler = { _, _, _, _ in
            for url in fileURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
