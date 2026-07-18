// SnapshotHelper.swift
//
// This file was provided by fastlane (https://github.com/fastlane/fastlane/tree/master/snapshot)
// and is dropped in verbatim so `bundle exec fastlane screenshots` can drive
// this target. Regenerate it with `bundle exec fastlane snapshot init` (or
// copy it fresh from the fastlane gem's `snapshot/lib/assets/SnapshotHelper.swift`)
// if the installed fastlane version in Gemfile.lock ever expects a different
// contract than the one below — don't hand-edit it otherwise.
//
// swiftlint:disable all

import Foundation
import XCTest

var deviceLanguage = ""
var locale = ""

func setupSnapshot(_ app: XCUIApplication, waitForAnimations: Bool = true) {
    Snapshot.setupSnapshot(app, waitForAnimations: waitForAnimations)
}

func snapshot(_ name: String, waitForLoadingIndicator: Bool = true) {
    Snapshot.snapshot(name, waitForLoadingIndicator: waitForLoadingIndicator)
}

@objcMembers
open class Snapshot: NSObject {
    static var app: XCUIApplication?
    static var waitForAnimations = true
    static var cacheDirectory: URL?
    static var screenshotsDirectory: URL? {
        return cacheDirectory?.appendingPathComponent("screenshots", isDirectory: true)
    }

    open class func setupSnapshot(_ app: XCUIApplication, waitForAnimations: Bool = true) {
        Snapshot.app = app
        Snapshot.waitForAnimations = waitForAnimations

        do {
            let cacheDir = try setupCacheDirectory()
            Snapshot.cacheDirectory = cacheDir
            setLanguage(app)
            setLocale(app)
            setLaunchArguments(app)
        } catch let error {
            NSLog("fastlane: \(error)")
        }
    }

    class func setLanguage(_ app: XCUIApplication) {
        guard let cacheDirectory = self.cacheDirectory else {
            NSLog("fastlane: cacheDirectory is not set - please make sure to call setupSnapshot before setLanguage")
            return
        }

        let path = cacheDirectory.appendingPathComponent("language.txt")

        do {
            let trimCharacterSet = CharacterSet.whitespacesAndNewlines
            deviceLanguage = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: trimCharacterSet)
            app.launchArguments += ["-AppleLanguages", "(\(deviceLanguage))"]
        } catch {
            NSLog("Couldn't detect/set language...")
        }
    }

    class func setLocale(_ app: XCUIApplication) {
        guard let cacheDirectory = self.cacheDirectory else {
            NSLog("fastlane: cacheDirectory is not set - please make sure to call setupSnapshot before setLocale")
            return
        }

        let path = cacheDirectory.appendingPathComponent("locale.txt")

        do {
            let trimCharacterSet = CharacterSet.whitespacesAndNewlines
            locale = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: trimCharacterSet)
        } catch {
            NSLog("Couldn't detect/set locale...")
        }

        if locale.isEmpty {
            locale = Locale(identifier: deviceLanguage).identifier
        }

        app.launchArguments += ["-AppleLocale", "\"\(locale)\""]
    }

    class func setLaunchArguments(_ app: XCUIApplication) {
        guard let cacheDirectory = self.cacheDirectory else {
            NSLog("fastlane: cacheDirectory is not set - please make sure to call setupSnapshot before setLaunchArguments")
            return
        }

        let path = cacheDirectory.appendingPathComponent("snapshot-launch_arguments.txt")
        app.launchArguments += ["-FASTLANE_SNAPSHOT", "YES", "-ui_testing"]

        do {
            let launchArguments = try String(contentsOf: path, encoding: String.Encoding.utf8)
            let regex = try NSRegularExpression(pattern: "(\\\".+?\\\"|\\S+)", options: [])
            let matches = regex.matches(in: launchArguments, options: [], range: NSRange(location: 0, length: launchArguments.count))
            let results = matches.map { result -> String in
                (launchArguments as NSString).substring(with: result.range)
            }
            app.launchArguments += results
        } catch {
            NSLog("Couldn't detect/set launch_arguments...")
        }
    }

    open class func snapshot(_ name: String, waitForLoadingIndicator: Bool = true) {
        if waitForLoadingIndicator {
            Snapshot.waitForLoadingIndicatorToDisappear()
        }

        NSLog("snapshot: \(name)") // more information about this, check out https://docs.fastlane.tools/actions/snapshot/#how-does-it-work

        if Snapshot.waitForAnimations {
            sleep(1)
        }

        guard let app = self.app else {
            NSLog("fastlane: XCUIApplication is not set. Please make sure to call setupSnapshot before snapshot.")
            return
        }

        guard let screenshotsDir = Snapshot.screenshotsDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("fastlane: could not create screenshots directory: \(error)")
        }

        let screenshot = app.windows.firstMatch.screenshot()
        let path = screenshotsDir.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: path)
        } catch {
            NSLog("fastlane: could not save screenshot \(name): \(error)")
        }

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "fastlane: \(name)") { activity in
            activity.add(attachment)
        }
    }

    class func waitForLoadingIndicatorToDisappear() {
        guard let app = self.app else { return }
        let networkLoadingIndicator = app.otherElements.deviceStatusBars.matching(identifier: "NetworkLoadingIndicator").firstMatch
        let networkLoadingIndicatorDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: networkLoadingIndicator
        )
        _ = XCTWaiter.wait(for: [networkLoadingIndicatorDisappeared], timeout: 20)
    }

    class func setupCacheDirectory() throws -> URL {
        let homeDir = URL(fileURLWithPath: NSHomeDirectory())
        let simulatorHostHome = ProcessInfo().environment["SIMULATOR_HOST_HOME"].flatMap(URL.init(fileURLWithPath:))
        let cacheDir = (simulatorHostHome ?? homeDir)
            .appendingPathComponent("Library/Caches/tools.fastlane")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
        return cacheDir
    }
}

private extension XCUIElementQuery {
    var deviceStatusBars: XCUIElementQuery {
        return self.matching(NSPredicate(format: "self.elementType == %d", XCUIElement.ElementType.statusBar.rawValue))
    }
}

// swiftlint:enable all
