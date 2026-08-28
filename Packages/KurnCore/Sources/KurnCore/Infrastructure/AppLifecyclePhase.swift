//
//  AppLifecyclePhase.swift
//  KurnCore
//
//  Portable stand-in for SwiftUI's `ScenePhase`, which KurnCore cannot import
//  (SwiftUI doesn't exist on Linux). The app maps `ScenePhase` to this at its
//  one call site; the decision logic in `SecurityCoverState` only ever needs
//  to know which of these three states it's in.
//

public enum AppLifecyclePhase: Sendable, Equatable {
    case active
    case inactive
    case background
}
