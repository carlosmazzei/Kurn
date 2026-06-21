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
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
