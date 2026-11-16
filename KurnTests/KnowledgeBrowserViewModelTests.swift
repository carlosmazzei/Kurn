import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct KnowledgeBrowserViewModelTests {
    private final class Audio: KnowledgeEvidenceAudio {
        var isPlaying = false
        var loads = 0
        var plays = 0
        var position: TimeInterval?
        var onLoad: (() -> Void)?
        func load(fileName: String, title: String?, subtitle: String?, enhanced: Bool) async throws { loads += 1; onLoad?() }
        func seek(to time: TimeInterval) { position = time }
        func play() { plays += 1; isPlaying = true }
        func stop() { isPlaying = false }
    }

    private func fixture() throws -> KnowledgeBrowserRead {
        let meetingID = UUID(), entityID = UUID()
        let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 12.345, endTime: 15, text: "The Example portal is not open.")
        let evidence = KnowledgeWikiSnapshot.Evidence(id: UUID(), recordingID: UUID(), segmentIDs: [segment.id.uuidString.lowercased()],
            quote: segment.text, startMs: 12_345, endMs: 15_000, attributedSpeaker: segment.speakerLabel)
        let fact = KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: entityID, predicate: .hasStatus, value: .enumeration("open"),
            qualifiers: .init(modality: .reported, polarity: .negative, claimKind: .internalStatusReport,
                authority: .attributed, confidence: .low, review: .machineExtracted),
            source: .init(meetingID: meetingID, recordedAt: Date(), evidence: [evidence]))
        let wiki = KnowledgeWikiSnapshot(revision: 1, entities: [.init(id: entityID, kind: .project, name: "Example portal")], facts: [fact])
        let entry = try #require(KnowledgeWikiProjector.project(wiki).first?.sections.first?.entries.first)
        let source = KnowledgeEvidenceRead(entry: entry, evidence: evidence, meetingTitle: "Example review", fileName: "synthetic.m4a",
            transcriptFingerprint: "synthetic-v1", segments: [segment])
        return try KnowledgeBrowserRead(meetingIDs: [meetingID], wiki: wiki, meetingTitles: [meetingID: source.meetingTitle], selectedEvidence: source)
    }

    private func selection(_ read: KnowledgeBrowserRead) throws -> KnowledgeEvidenceSelection {
        let source = try #require(read.selectedEvidence)
        return .init(assertionID: source.entry.fact.id, evidenceID: source.evidence.id)
    }

    @Test func dtoRejectsForeignSourcesAndMetadata() throws {
        let read = try fixture()
        let wiki = KnowledgeWikiSnapshot(revision: 1, entities: read.pages.map(\.entity), facts: [try #require(read.selectedEvidence).entry.fact])
        #expect(throws: KnowledgeWikiStoreError.scopeDenied) {
            try KnowledgeBrowserRead(meetingIDs: [UUID()], wiki: wiki, meetingTitles: read.meetingTitles)
        }
        #expect(throws: KnowledgeWikiStoreError.scopeDenied) {
            try KnowledgeBrowserRead(meetingIDs: read.meetingIDs, wiki: wiki, meetingTitles: [:])
        }
        let tooMany = Set((0..<17).map { _ in UUID() })
        #expect(throws: KnowledgeWikiStoreError.scopeDenied) {
            try KnowledgeBrowserRead(meetingIDs: tooMany, wiki: .init(revision: 0, entities: [], facts: []),
                meetingTitles: Dictionary(uniqueKeysWithValues: tooMany.map { ($0, "Example") }))
        }
    }

    @Test func routesNeverExposeAnotherScopeOrEvidence() async throws {
        let read = try fixture(), selected = try selection(read)
        let model = KnowledgeBrowserViewModel(audio: Audio())
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { read })
        #expect(model.state == .loaded(read))
        #expect(model.presentation(meetingIDs: [UUID()], selection: selected) == .idle)
        #expect(model.presentation(meetingIDs: read.meetingIDs, selection: .init(assertionID: UUID(), evidenceID: UUID())) == .idle)
        #expect(model.presentation(meetingIDs: read.meetingIDs, selection: nil) == .idle)
        #expect(KnowledgeBrowserRoute.evidence(assertionID: selected.assertionID, evidenceID: selected.evidenceID).evidenceSelection == selected)
        #expect(KnowledgeBrowserRoute.transcript(assertionID: selected.assertionID, evidenceID: selected.evidenceID).evidenceSelection == selected)
    }

    @Test func disabledFailedForeignAndInvalidatedReadsClearContent() async throws {
        let read = try fixture(), selected = try selection(read)
        let model = KnowledgeBrowserViewModel(audio: Audio())
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { false }, reader: { Issue.record("Disabled read"); return read })
        #expect(model.state == .idle)
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { read })
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { throw KnowledgeWikiStoreError.scopeDenied })
        #expect(model.state == .unavailable)
        await model.load(meetingIDs: [UUID()], selection: selected, isEnabled: { true }, reader: { read })
        #expect(model.state == .unavailable)
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { model.invalidate(); return read })
        #expect(model.state == .idle)
    }

    @Test func aSupersededReadCannotReplaceTheNewerResult() async throws {
        let read = try fixture(), selected = try selection(read)
        let newer = try fixture(), newerSelection = try selection(newer)
        let model = KnowledgeBrowserViewModel(audio: Audio())
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: {
            await model.load(meetingIDs: newer.meetingIDs, selection: newerSelection, isEnabled: { true }, reader: { newer })
            return read
        })
        #expect(model.state == .loaded(newer))
    }

    @Test func audioSeeksToTheRecordingRelativeCitationOnlyAfterTwoReads() async throws {
        let read = try fixture(), selected = try selection(read)
        let audio = Audio(), model = KnowledgeBrowserViewModel(audio: audio)
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { read })
        var checks = 0
        await model.playEvidence(isEnabled: { true }, reader: { checks += 1; return read })
        #expect(checks == 2)
        #expect(audio.loads == 1 && audio.plays == 1)
        #expect(audio.position == 12.345)
        model.invalidate()
        #expect(!audio.isPlaying && model.state == .idle)
    }

    @Test func revocationDuringAudioSetupPreventsPlaybackAndClearsContent() async throws {
        let read = try fixture(), selected = try selection(read)
        let audio = Audio(), model = KnowledgeBrowserViewModel(audio: audio)
        var enabled = true
        audio.onLoad = { enabled = false }
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { enabled }, reader: { read })
        await model.playEvidence(isEnabled: { enabled }, reader: { read })
        #expect(audio.plays == 0 && !audio.isPlaying)
        #expect(model.state == .unavailable)
    }

    @Test func changedOrDeniedEvidenceAfterAudioSetupCannotPlay() async throws {
        let read = try fixture(), selected = try selection(read)
        let source = try #require(read.selectedEvidence)
        let moved = KnowledgeEvidenceRead(entry: source.entry, evidence: source.evidence, meetingTitle: source.meetingTitle,
            fileName: "moved-synthetic.m4a", transcriptFingerprint: source.transcriptFingerprint, segments: source.segments)
        let changed = try KnowledgeBrowserRead(meetingIDs: read.meetingIDs,
            wiki: .init(revision: 1, entities: read.pages.map(\.entity), facts: [source.entry.fact]),
            meetingTitles: read.meetingTitles, selectedEvidence: moved)
        let audio = Audio(), model = KnowledgeBrowserViewModel(audio: audio)
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { read })
        var checks = 0
        await model.playEvidence(isEnabled: { true }, reader: { checks += 1; return checks == 1 ? read : changed })
        #expect(audio.plays == 0 && model.state == .unavailable)
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { read })
        checks = 0
        await model.playEvidence(isEnabled: { true }, reader: {
            checks += 1
            if checks == 2 { throw KnowledgeWikiStoreError.scopeDenied }
            return read
        })
        #expect(audio.plays == 0 && model.state == .unavailable)
    }

    @Test func invalidationDuringAudioSetupCannotResurrectPlayback() async throws {
        let read = try fixture(), selected = try selection(read)
        let audio = Audio(), model = KnowledgeBrowserViewModel(audio: audio)
        audio.onLoad = { model.invalidate() }
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { read })
        await model.playEvidence(isEnabled: { true }, reader: { read })
        #expect(audio.plays == 0 && !audio.isPlaying)
        #expect(!model.isLoadingAudio && model.state == .idle)
    }

    @Test func cancellationNeverPublishesAReadOrStartsAudio() async throws {
        let read = try fixture(), selected = try selection(read)
        let audio = Audio(), model = KnowledgeBrowserViewModel(audio: audio)
        let task = Task {
            await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: {
                withUnsafeCurrentTask { $0?.cancel() }
                return read
            })
        }
        await task.value
        #expect(model.state == .idle && audio.plays == 0)
        await model.load(meetingIDs: read.meetingIDs, selection: selected, isEnabled: { true }, reader: { throw CancellationError() })
        #expect(model.state == .idle)
    }
}
