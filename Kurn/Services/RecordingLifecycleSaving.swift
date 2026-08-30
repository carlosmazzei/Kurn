import SwiftData

@MainActor
protocol RecordingLifecycleSaving {
    func save(_ context: ModelContext) throws
}

struct ModelContextRecordingLifecycleSaver: RecordingLifecycleSaving {
    func save(_ context: ModelContext) throws {
        try context.save()
    }
}
