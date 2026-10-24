//
//  PDFFixtures.swift
//  KurnTests
//
//  Real PDFs written at run time with UIKit's PDF renderer, so the attachment
//  tests exercise PDFKit against genuine documents rather than mocks: one
//  page per string (an empty string is a page with no text layer at all,
//  the shape of a scan), optionally encrypted with a password.
//

import Foundation
import UIKit

enum PDFFixtures {
    static func makePDF(pages: [String], password: String? = nil, name: String? = nil) throws -> URL {
        let format = UIGraphicsPDFRendererFormat()
        if let password {
            format.documentInfo = [
                kCGPDFContextUserPassword as String: password,
                kCGPDFContextOwnerPassword as String: password
            ]
        }
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let data = renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                guard !text.isEmpty else { continue }
                (text as NSString).draw(
                    in: bounds.insetBy(dx: 40, dy: 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
                )
            }
        }
        return try write(data, name: name)
    }

    /// A file named `.pdf` that is not one.
    static func makeNonPDF() throws -> URL {
        try write(Data("definitely not a PDF".utf8), name: nil)
    }

    private static func write(_ data: Data, name: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name ?? "fixture.pdf")
        try data.write(to: url)
        return url
    }

    /// Removes a fixture and the folder it was written into.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
