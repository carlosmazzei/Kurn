//
//  PhotoCaptureDecisionsTests.swift
//  KurnTests
//
//  The decisions behind the in-recording camera and its OCR, kept out of the
//  AVFoundation and Vision adapters: the flash toggle's cycle, the zoom
//  clamp, the reading order a photographed page is reconstructed in, and
//  that OCR never fails a capture.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Kurn

struct PhotoCaptureDecisionsTests {

    // MARK: - Flash

    @Test func theFlashToggleCyclesThroughEveryModeWithItsOwnIcon() {
        var mode = PhotoFlashMode.auto
        var seen: [PhotoFlashMode] = []
        for _ in PhotoFlashMode.allCases {
            seen.append(mode)
            mode = mode.next
        }
        #expect(mode == .auto)
        #expect(Set(seen) == Set(PhotoFlashMode.allCases))
        #expect(Set(PhotoFlashMode.allCases.map(\.systemImage)).count == PhotoFlashMode.allCases.count)
    }

    // MARK: - Zoom

    @Test func zoomIsCappedAtSixOrTheDevicesOwnCeiling() {
        #expect(PhotoZoom.maxFactor(deviceMax: 120) == 6)
        #expect(PhotoZoom.maxFactor(deviceMax: 3) == 3)
    }

    @Test func aRequestedZoomIsClampedIntoRange() {
        #expect(PhotoZoom.clamp(0.2, deviceMax: 10) == 1)
        #expect(PhotoZoom.clamp(2.5, deviceMax: 10) == 2.5)
        #expect(PhotoZoom.clamp(40, deviceMax: 10) == 6)
        #expect(PhotoZoom.clamp(5, deviceMax: 4) == 4)
    }

    // MARK: - OCR reading order

    @Test func linesReadTopToBottomThenLeftToRight() {
        // Vision's boxes are normalized with a bottom-left origin.
        let text = PhotoTextRecognizer.readingOrder([
            (box: CGRect(x: 0.6, y: 0.10, width: 0.2, height: 0.05), text: "bottom"),
            (box: CGRect(x: 0.5, y: 0.80, width: 0.2, height: 0.05), text: "top right"),
            (box: CGRect(x: 0.1, y: 0.802, width: 0.2, height: 0.05), text: "top left"),
            (box: CGRect(x: 0.1, y: 0.45, width: 0.2, height: 0.05), text: "middle")
        ])
        #expect(text == "top left\ntop right\nmiddle\nbottom")
    }

    @Test func noRecognizedLinesIsNoText() {
        #expect(PhotoTextRecognizer.readingOrder([]) == nil)
    }

    // MARK: - OCR never fails a capture

    @Test func anUnreadableOrBlankPhotoYieldsNoText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoCaptureDecisionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await PhotoTextRecognizer.recognizeText(at: directory.appendingPathComponent("missing.jpg")) == nil)

        let notAnImage = directory.appendingPathComponent("notes.jpg")
        try Data("not an image".utf8).write(to: notAnImage)
        #expect(await PhotoTextRecognizer.recognizeText(at: notAnImage) == nil)

        let blank = directory.appendingPathComponent("blank.png")
        try Self.writeBlankPNG(to: blank)
        #expect(await PhotoTextRecognizer.recognizeText(at: blank) == nil)
    }

    private static func writeBlankPNG(to url: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
