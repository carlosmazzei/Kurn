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
import UIKit
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

    @Test func zoomCeilingIsSixTimesTheMainLensNotTheUltraWide() {
        #expect(PhotoZoom.maxFactor(deviceMax: 120, base: 2) == 12)
        #expect(PhotoZoom.clamp(30, deviceMax: 120, base: 2) == 12)
        #expect(PhotoZoom.clamp(0.5, deviceMax: 120, base: 2) == 1)
    }

    @Test func aTripleCameraOffersUltraWideMainCroppedTwoTimesAndTelephotoButtons() {
        // iPhone Pro: ultra-wide at 1, main at 2, telephoto at 6 (3x), with a
        // 2x crop of the main sensor in between.
        let stops = PhotoZoom.lensStops(switchOverFactors: [2, 6], hasUltraWide: true, deviceMax: 120)
        #expect(stops.map(\.deviceFactor) == [1, 2, 4, 6])
        #expect(stops.map(\.displayFactor) == [0.5, 1, 2, 3])
    }

    @Test func aDualWideCameraAddsACroppedTwoTimesButton() {
        let stops = PhotoZoom.lensStops(switchOverFactors: [2], hasUltraWide: true, deviceMax: 120)
        #expect(stops.map(\.displayFactor) == [0.5, 1, 2])
        #expect(stops.map(\.deviceFactor) == [1, 2, 4])
    }

    @Test func aSingleCameraOffersOneTimesAndACroppedTwoTimes() {
        let stops = PhotoZoom.lensStops(switchOverFactors: [], hasUltraWide: false, deviceMax: 10)
        #expect(stops.map(\.deviceFactor) == [1, 2])
        #expect(PhotoZoom.lensStops(switchOverFactors: [], hasUltraWide: false, deviceMax: 1.5).count == 1)
    }

    @Test func theSelectedButtonIsTheLastLensAtOrBelowTheZoom() {
        let stops = PhotoZoom.lensStops(switchOverFactors: [2, 6], hasUltraWide: true, deviceMax: 120)
        #expect(PhotoZoom.activeStop(in: stops, zoomFactor: 1)?.deviceFactor == 1)
        #expect(PhotoZoom.activeStop(in: stops, zoomFactor: 3.4)?.deviceFactor == 2)
        #expect(PhotoZoom.activeStop(in: stops, zoomFactor: 6)?.deviceFactor == 6)
    }

    @Test func lensLabelsDropAnUnneededDecimal() {
        #expect(PhotoZoom.label(displayFactor: 1) == "1")
        #expect(PhotoZoom.label(displayFactor: 3.0000001) == "3")
    }

    // MARK: - Timer

    @Test func theTimerOffersOffThreeAndTenSeconds() {
        #expect(PhotoTimer.allCases.map(\.seconds) == [0, 3, 10])
    }

    // MARK: - Exposure

    @Test func draggingTheSunUpBrightensAndDownDarkens() {
        #expect(PhotoExposure.level(afterDrag: -25, from: 0) == 0.5)
        #expect(PhotoExposure.level(afterDrag: 25, from: 0) == -0.5)
        #expect(PhotoExposure.level(afterDrag: -500, from: 0.2) == 1)
        #expect(PhotoExposure.level(afterDrag: 500, from: 0.2) == -1)
    }

    @Test func exposureBiasStaysWithinTheDeviceAndTwoStops() {
        #expect(PhotoExposure.bias(level: 1, deviceMin: -8, deviceMax: 8) == 2)
        #expect(PhotoExposure.bias(level: -1, deviceMin: -1, deviceMax: 8) == -1)
        #expect(PhotoExposure.bias(level: 0, deviceMin: -8, deviceMax: 8) == 0)
    }

    // MARK: - Control rotation

    @Test func controlsCounterRotateWithThePhone() {
        #expect(PhotoControlRotation.degrees(for: .portrait) == 0)
        #expect(PhotoControlRotation.degrees(for: .landscapeLeft) == 90)
        #expect(PhotoControlRotation.degrees(for: .landscapeRight) == -90)
        #expect(PhotoControlRotation.degrees(for: .faceUp) == nil)
        #expect(PhotoControlRotation.degrees(for: .portraitUpsideDown) == nil)
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
