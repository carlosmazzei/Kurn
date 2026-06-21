//
//  KurnWatchApp.swift
//  KurnWatch
//
//  Entry point for the Watch companion app: a remote control for a recording
//  already started on the iPhone. No local persistence — all state comes
//  from WatchConnectivity.
//

import SwiftUI

@main
struct KurnWatchApp: App {
    @State private var connectivity = WatchConnectivityManager()

    var body: some Scene {
        WindowGroup {
            WatchRecorderView()
                .environment(connectivity)
        }
    }
}
