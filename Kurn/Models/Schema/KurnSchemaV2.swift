//
//  KurnSchemaV2.swift
//  Kurn
//
//  Current on-disk schema. Adds the `Folder` entity and `Meeting.folder`
//  relationship on top of V1. The model types referenced here are the
//  top-level ones in `Models/` — the app uses them directly without any
//  type alias indirection.
//

import Foundation
import SwiftData

enum KurnSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Meeting.self,
            Recording.self,
            Transcript.self,
            Speaker.self,
            Summary.self,
            Folder.self
        ]
    }
}
