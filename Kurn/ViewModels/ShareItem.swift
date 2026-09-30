//
//  ShareItem.swift
//  Kurn
//
//  Lives with the view models rather than beside `ActivityView`, which
//  presents it: view models build share items (`ModelStoreRecoveryViewModel`),
//  and a view model must not depend on a type declared in `Views/`.
//

import Foundation

/// Wraps one or more URLs so they can drive `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}
