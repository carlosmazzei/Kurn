import SwiftData

struct RecordingFileReferences {
    var recordings: (ModelContext) throws -> [Recording] = { try $0.fetch(FetchDescriptor<Recording>()) }
    var photos: (ModelContext) throws -> [MeetingPhoto] = { try $0.fetch(FetchDescriptor<MeetingPhoto>()) }
    var attachments: (ModelContext) throws -> [MeetingAttachment] = { try $0.fetch(FetchDescriptor<MeetingAttachment>()) }

    func fileNames(context: ModelContext) throws -> Set<String> {
        let recordings = try recordings(context)
        let photos = try photos(context)
        let attachments = try attachments(context)
        return Set(recordings.map(\.fileName))
            .union(photos.map(\.fileName))
            .union(attachments.map(\.fileName))
    }
}
