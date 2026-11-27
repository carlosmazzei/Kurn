import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K5.1: the chat's read-only knowledge tools and the gate that decides whether a run may use them.
@MainActor
struct ChatKnowledgeToolsTests {
    private nonisolated static let meeting = UUID(), project = UUID(), team = UUID()
    private nonisolated static let blocker = UUID(), status = UUID(), evidenceID = UUID(), recording = UUID()

    /// K7.1: the blocker was said a month before it was recorded into knowledge; the other claim has no source time.
    private nonisolated static let said = Date(timeIntervalSince1970: 1_787_000_000)

    private nonisolated static let entities: [KnowledgeWikiSnapshot.Entity] = [
        .init(id: project, kind: .project, name: "Example portal", aliases: ["Portal"]),
        .init(id: team, kind: .team, name: "Platform team"),
    ]

    private nonisolated static func wiki() -> KnowledgeWikiSnapshot {
        func source(_ quote: String, evidence: UUID = UUID(), observedAt: Date? = nil) -> KnowledgeWikiSnapshot.Source {
            .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_790_000_000), observedAt: observedAt, evidence: [
                .init(id: evidence, recordingID: recording, segmentIDs: ["s1"], quote: quote, startMs: 65_000, endMs: 70_000,
                      attributedSpeaker: "Speaker 2"),
            ])
        }
        let facts: [KnowledgeWikiSnapshot.Fact] = [
            .init(id: blocker, subjectID: team, predicate: .blocks, objectID: project,
                  qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                    confidence: .medium, review: .machineExtracted,
                                    validFrom: KnowledgeTemporalValue(text: "2026-10", precision: .month),
                                    validTo: KnowledgeTemporalValue(text: "2026-11", precision: .month)),
                  source: source("The platform team is blocking the portal.", evidence: evidenceID, observedAt: said)),
            .init(id: status, subjectID: project, predicate: .hasStatus, value: .enumeration("open"),
                  qualifiers: .init(modality: .proposed, polarity: .negative, claimKind: .internalStatusReport, authority: .attributed,
                                    confidence: .medium, review: .machineExtracted),
                  source: source("The portal is not open yet.")),
        ]
        return KnowledgeWikiSnapshot(revision: 7, entities: entities, facts: facts)
    }

    private nonisolated static func read(_ selection: KnowledgeEvidenceSelection?,
                             classification: KnowledgeClassification = .internal) throws -> KnowledgeBrowserRead {
        let snapshot = wiki()
        var evidence: KnowledgeEvidenceRead?
        if let selection {
            let pages = try KnowledgeWikiProjector.project(snapshot)
            guard let entry = pages.flatMap({ $0.sections.flatMap(\.entries) }).first(where: { $0.fact.id == selection.assertionID }),
                  let cited = entry.fact.source.evidence.first(where: { $0.id == selection.evidenceID }) else {
                throw KnowledgeWikiStoreError.scopeDenied
            }
            evidence = KnowledgeEvidenceRead(entry: entry, evidence: cited, meetingTitle: "Weekly review", fileName: "a.m4a",
                                             transcriptFingerprint: "f", segments: [])
        }
        return try KnowledgeBrowserRead(meetingIDs: [meeting], wiki: snapshot, meetingTitles: [meeting: "Weekly review"],
                                        selectedEvidence: evidence, policyRevisionKey: "p1",
                                        meetingContexts: [meeting: .init(id: UUID(), kind: .vendorDiscussion, name: "Sync",
                                                                         classification: classification)])
    }

    /// A policy that lets OpenAI answer from internal knowledge.
    private static let permissive = KnowledgeProcessingPolicy(allowedRemoteProviderIDs: [AIProvider.openAI.id],
                                                              maxRemoteClassification: .internal)

    private static func source(policy: KnowledgeProcessingPolicy = permissive, consent: Bool = true, enabled: Bool = true,
                               allowed: Set<UUID>? = nil, classification: KnowledgeClassification = .internal) -> ChatKnowledgeSource {
        ChatKnowledgeSource(
            read: { _, selection in try read(selection, classification: classification) },
            authorization: { ids in
                KnowledgeSourceAuthorization(featureEnabled: enabled, meetingIDs: allowed ?? ids, policies: [policy],
                                             sourceClassifications: [.internal])
            },
            remoteConsent: { _ in consent })
    }

    private func run(_ name: String, _ arguments: [String: JSONValue],
                     source: ChatKnowledgeSource? = nil) async throws -> AgentToolOutput {
        let tools = ChatKnowledgeTools.make(source: source ?? Self.source(), meetings: [Self.meeting], provider: .openAI)
        return try await #require(tools.first { $0.spec.name == name }).execute(.object(arguments))
    }

    /// K7.1: `as_of` reads only what had been said in meetings held by the end of that UTC day. The blocker was said on
    /// 2026-08-17; the other claim has no known meeting date.
    @Test func asOfReadsOnlyWhatHadBeenSaidByThatDayAndCountsWhatItLeavesOut() async throws {
        let project = JSONValue.string(Self.project.uuidString)
        let before = try await run("get_entity", ["entityID": project, "as_of": .string("2026-08-16")])
        #expect(!before.isError)
        #expect(before.content.contains("as of 2026-08-16 (by meeting date): 0 claims shown; left out: 1 said later, "
            + "1 with no known meeting date; generated narratives omitted"))
        #expect(!before.content.contains("Platform team blocks Example portal"))
        // The page itself is still there: nothing had been said, which is not the same as an unknown entity.
        #expect(before.content.contains("entity \(Self.project.uuidString)"))
        let sameDay = try await run("get_entity", ["entityID": project, "as_of": .string("2026-08-17")])
        #expect(sameDay.content.contains("1 claims shown; left out: 0 said later, 1 with no known meeting date"))
        #expect(sameDay.content.contains("Platform team blocks Example portal"))
        #expect(!sameDay.content.contains("NOT Example portal hasStatus open"))
        // Without as_of nothing is restricted and nothing is announced.
        let all = try await run("get_entity", ["entityID": project])
        #expect(all.content.contains("NOT Example portal hasStatus open") && !all.content.contains("as of "))
    }

    /// An entity page reports what it lost itself, not what the other selected entities lost.
    @Test func asOfCountsOnlyTheRequestedEntitysClaims() async throws {
        let first = UUID(), second = UUID(), firstFact = UUID(), secondFact = UUID()
        func fact(_ id: UUID, subject: UUID, said: Date) -> KnowledgeWikiSnapshot.Fact {
            .init(id: id, subjectID: subject, predicate: .hasStatus, value: .enumeration("open"),
                  qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport,
                                    authority: .attributed, confidence: .medium, review: .machineExtracted),
                  source: .init(meetingID: Self.meeting, recordedAt: Date(timeIntervalSince1970: 1_790_000_000), observedAt: said,
                                evidence: [.init(id: UUID(), recordingID: Self.recording, segmentIDs: ["s1"], quote: "q",
                                                 startMs: 1_000, endMs: 2_000, attributedSpeaker: "Speaker 1")]))
        }
        // The first entity's only claim was said on 2026-08-17; the second entity's was said in May, so a count over
        // every page would report one claim shown for the first.
        let wiki = KnowledgeWikiSnapshot(
            revision: 3,
            entities: [.init(id: first, kind: .project, name: "Example alpha"), .init(id: second, kind: .project, name: "Example beta")],
            facts: [fact(firstFact, subject: first, said: Date(timeIntervalSince1970: 1_787_000_000)),
                    fact(secondFact, subject: second, said: Date(timeIntervalSince1970: 1_780_000_000))])
        let read = try KnowledgeBrowserRead(meetingIDs: [Self.meeting], wiki: wiki, meetingTitles: [Self.meeting: "Weekly review"],
                                            selectedEvidence: nil, policyRevisionKey: "p1",
                                            meetingContexts: [Self.meeting: .init(id: UUID(), kind: .vendorDiscussion, name: "Sync",
                                                                                  classification: .internal)])
        let source = ChatKnowledgeSource(read: { _, _ in read }, authorization: Self.source().authorization, remoteConsent: { _ in true })
        let output = try await run("get_entity", ["entityID": .string(first.uuidString), "as_of": .string("2026-08-16")], source: source)
        #expect(!output.isError)
        #expect(output.content.contains("0 claims shown; left out: 1 said later, 0 with no known meeting date"))
        #expect(!output.content.contains("1 claims shown"))
        // Search spans every selected page, so it reports the whole selection: one shown (beta), one said later (alpha).
        let search = try await run("search_knowledge", ["query": .string("Example"), "as_of": .string("2026-08-16")], source: source)
        #expect(search.content.contains("1 claims shown; left out: 1 said later, 0 with no known meeting date"))
    }

    @Test func asOfSaysItLimitsClaimsNotTheNamesUsedToFindThem() throws {
        let tools = ChatKnowledgeTools.make(source: Self.source(), meetings: [Self.meeting], provider: .openAI)
        let schema = try #require(tools.first { $0.spec.name == "get_entity" }).spec.inputSchema
        guard case .object(let root) = schema, case .object(let properties)? = root["properties"],
              case .object(let asOf)? = properties["as_of"], case .string(let text)? = asOf["description"] else {
            Issue.record("get_entity declares no as_of description")
            return
        }
        #expect(text.contains("are today's"))
        #expect(text.contains("not the names"))
    }

    @Test func asOfRestrictsSearchWithoutLeakingALaterClaimThroughAPageHit() async throws {
        let early = try await run("search_knowledge", ["query": .string("portal"), "as_of": .string("2026-08-16")])
        #expect(!early.isError)
        #expect(early.content.contains("as of 2026-08-16 (by meeting date)"))
        #expect(!early.content.contains("assertion \(Self.blocker.uuidString)"))
        // Page and alias hits are built from the claims they summarize, so none survives when no claim does.
        #expect(!early.content.contains("entity \(Self.project.uuidString)"))
        let late = try await run("search_knowledge", ["query": .string("portal"), "as_of": .string("2026-08-17")])
        #expect(late.content.contains("assertion \(Self.blocker.uuidString)"))
        #expect(!late.content.contains("assertion \(Self.status.uuidString)"))
    }

    @Test func asOfMustBeACalendarDayAndIsOnlyOfferedToTheToolsThatHonourIt() async throws {
        let project = JSONValue.string(Self.project.uuidString)
        for bad in ["tomorrow", "2026-13-40", "2026-08", "2026-08-17T10:00:00Z"] {
            #expect(try await run("get_entity", ["entityID": project, "as_of": .string(bad)]).isError, "\(bad)")
        }
        #expect(try await run("get_entity", ["entityID": project, "as_of": .number(1)]).isError)
        // Tools that do not read it refuse it rather than ignoring it.
        #expect(try await run("get_timeline", ["as_of": .string("2026-08-17")]).isError)
        let tools = ChatKnowledgeTools.make(source: Self.source(), meetings: [Self.meeting], provider: .openAI)
        for name in ["search_knowledge", "get_entity"] {
            let spec = try #require(tools.first { $0.spec.name == name }).spec
            #expect(String(describing: spec.inputSchema).contains("as_of"), "\(name)")
        }
        #expect(!String(describing: try #require(tools.first { $0.spec.name == "get_timeline" }).spec.inputSchema).contains("as_of"))
    }

    @Test func theGateOffersKnowledgeOnlyWhenPolicyAndConsentAllowIt() {
        let ids: Set<UUID> = [Self.meeting]
        #expect(ChatKnowledgeGate.meetings(ids, source: Self.source(), provider: .openAI) == ids)
        // The default policy keeps knowledge on the device; consent alone never lets it out.
        #expect(ChatKnowledgeGate.meetings(ids, source: Self.source(policy: .defaultDeny()), provider: .openAI) == nil)
        // A policy alone never stands in for the person's consent.
        #expect(ChatKnowledgeGate.meetings(ids, source: Self.source(consent: false), provider: .openAI) == nil)
        // Another provider than the one the policy names.
        #expect(ChatKnowledgeGate.meetings(ids, source: Self.source(), provider: .anthropic) == nil)
        #expect(ChatKnowledgeGate.meetings(ids, source: Self.source(enabled: false), provider: .openAI) == nil)
        // Confidential sources are above the policy's remote ceiling.
        let confidential = ChatKnowledgeGate.meetings(ids, source: Self.source(), provider: .openAI, classifications: [.confidential])
        #expect(confidential == nil)
        // Only meetings the controls allow, and never more than the reader's bound.
        let other = UUID()
        #expect(ChatKnowledgeGate.meetings(ids.union([other]), source: Self.source(allowed: [Self.meeting]), provider: .openAI) == ids)
        #expect(ChatKnowledgeGate.meetings(ids, source: Self.source(allowed: []), provider: .openAI) == nil)
        let many = Set((0...ChatKnowledgeGate.meetingLimit).map { _ in UUID() })
        #expect(ChatKnowledgeGate.meetings(many, source: Self.source(), provider: .openAI) == nil)
    }

    @Test func searchFindsClaimsAndAliasesWithTheirIDs() async throws {
        let output = try await run("search_knowledge", ["query": .string("portal")])
        #expect(!output.isError)
        #expect(output.content.hasPrefix("knowledge search results (best first; all matches):"))
        #expect(output.content.contains("entity \(Self.project.uuidString)"))
        #expect(output.content.contains("assertion \(Self.blocker.uuidString)"))
        #expect(output.content.hasSuffix("revision: 7; meetings: 1"))
        #expect(try await run("search_knowledge", ["query": .string("   ")]).isError)
        #expect(try await run("search_knowledge", ["query": .string("portal"), "extra": .bool(true)]).isError)
    }

    @Test func anEntityPageKeepsModalityNegationAndStatedTime() async throws {
        let output = try await run("get_entity", ["entityID": .string(Self.project.uuidString)])
        #expect(output.content.contains("entity \(Self.project.uuidString) | Example portal | kind: project | aliases: Portal"))
        #expect(output.content.contains("NOT Example portal hasStatus open | modality: proposed"))
        #expect(output.content.contains("Platform team blocks Example portal | modality: reported"))
        #expect(output.content.contains("valid from: 2026-10"))
        #expect(output.content.contains("| said \(ChatSourceToolText.date(Self.said))"))
        #expect(output.content.contains("evidence \(Self.evidenceID.uuidString) [1:05] Speaker 2: \"The platform team is blocking the portal.\""))
        #expect(output.content.contains("page: items 1–2 of 2; end"))
        let paged = try await run("get_entity", ["entityID": .string(Self.project.uuidString), "limit": .number(1)])
        #expect(paged.content.contains("page: items 1–1 of 2; next offset: 1"))
        #expect(try await run("get_entity", ["entityID": .string(UUID().uuidString)]).isError)
        #expect(try await run("get_entity", ["entityID": .string("not-a-uuid")]).isError)
        #expect(try await run("get_entity", ["entityID": .string(Self.project.uuidString), "limit": .number(21)]).isError)
        let wiki = try await run("get_wiki_page", ["entityID": .string(Self.project.uuidString)])
        #expect(wiki.content.contains("no generated narrative for this page; read its claims with get_entity"))
        #expect(try await run("get_wiki_page", ["entityID": .string(UUID().uuidString)]).isError)
    }

    @Test func theTimelinePutsStatedTimeFirstAndUndatedLast() async throws {
        let output = try await run("get_timeline", [:])
        let lines = output.content.split(separator: "\n").map(String.init)
        let dated = try #require(lines.firstIndex { $0.hasPrefix("- 2026-10 | Platform team blocks Example portal") })
        let undated = try #require(lines.firstIndex { $0.hasPrefix("- undated | NOT Example portal hasStatus open") })
        #expect(dated < undated)
        #expect(lines[undated].hasSuffix("| tentative") && lines[undated].contains("modality: proposed"))
        // Source time (K7.1) rides beside recorded time, and only when the claim's meeting date is known.
        #expect(lines[dated].contains("| recorded \(ChatSourceToolText.date(Date(timeIntervalSince1970: 1_790_000_000))) | said "
            + "\(ChatSourceToolText.date(Self.said))"))
        #expect(!lines[undated].contains("| said "))
        // Both ends of a stated validity reach the model.
        #expect(lines[dated].contains("modality: reported; kind: internalStatusReport; review: machineExtracted; "
            + "valid from: 2026-10; valid to: 2026-11"))
        let teamOnly = try await run("get_timeline", ["entityID": .string(Self.team.uuidString)])
        #expect(teamOnly.content.contains("blocks") && !teamOnly.content.contains("hasStatus"))
        #expect(try await run("get_timeline", ["entityID": .string(UUID().uuidString)]).isError)
    }

    @Test func evidenceReturnsTheCitedPassage() async throws {
        let output = try await run("get_evidence", ["assertionID": .string(Self.blocker.uuidString),
                                                    "evidenceID": .string(Self.evidenceID.uuidString)])
        #expect(output.content.contains("meeting \(Self.meeting.uuidString) | Weekly review | assertion \(Self.blocker.uuidString)"))
        #expect(output.content.contains("[1:05]–[1:10] Speaker 2: \"The platform team is blocking the portal.\""))
        #expect(output.content.contains("Platform team blocks Example portal | modality: reported"))
        #expect(output.content.contains("valid to: 2026-11"))
        #expect(try await run("get_evidence", ["assertionID": .string(Self.blocker.uuidString),
                                               "evidenceID": .string(UUID().uuidString)]).isError)
        #expect(try await run("get_evidence", ["assertionID": .string(Self.blocker.uuidString)]).isError)
    }

    @Test func everyCallIsAuthorizedAgainAfterItsRead() async throws {
        // Consent withdrawn after the run started: nothing is read or sent.
        let withdrawn = try await run("get_entity", ["entityID": .string(Self.project.uuidString)], source: Self.source(consent: false))
        #expect(withdrawn.isError && !withdrawn.content.contains("Example portal"))
        // A context reclassified above the policy's ceiling since the run started.
        let reclassified = try await run("search_knowledge", ["query": .string("portal")],
                                         source: Self.source(classification: .confidential))
        #expect(reclassified.isError && !reclassified.content.contains("Example portal"))
        let readFails = ChatKnowledgeSource(read: { _, _ in throw KnowledgeWikiStoreError.scopeDenied },
                                            authorization: Self.source().authorization, remoteConsent: { _ in true })
        let failed = try await run("get_timeline", [:], source: readFails)
        #expect(failed.isError && failed.content == "Knowledge tool error: Knowledge is unavailable for these sources.")
    }

    @Test func theProductionSourceConsentsOnlyUnderTheOnRequestGrant() async throws {
        let settings = MeetingFixtures.isolatedSettings()
        let coordinator = KnowledgeCompilationCoordinator(queue: KnowledgeJobQueue(container: TestModelContainer.make()), settings: settings)
        let source = ChatKnowledgeSource(coordinator: coordinator)
        #expect(!source.remoteConsent(.openAI))
        settings.grantCloudConsent(.openAI, for: .onRequest)
        #expect(source.remoteConsent(.openAI))
        // Knowledge is off by default, so nothing is authorized or offered.
        #expect(!source.authorization([Self.meeting]).featureEnabled)
        #expect(ChatKnowledgeGate.meetings([Self.meeting], source: source, provider: .openAI) == nil)
        await #expect(throws: (any Error).self) { try await source.read([Self.meeting], nil) }
    }

    @Test func theRevisionIsTheSnapshotsEvenWithoutVisibleClaims() throws {
        let empty = try KnowledgeBrowserRead(meetingIDs: [Self.meeting],
                                             wiki: KnowledgeWikiSnapshot(revision: 12, entities: [], facts: []),
                                             meetingTitles: [Self.meeting: "Weekly review"])
        #expect(empty.pages.isEmpty && empty.revision == 12)
        #expect(try Self.read(nil).revision == 7)
    }

    @Test func searchPagesARankedWindowAndSaysWhenItIsFull() async throws {
        // 60 entities whose page and claim both match: more matches than the window holds.
        let entities = (0..<60).map { KnowledgeWikiSnapshot.Entity(id: UUID(), kind: .project, name: "Portal \($0)") }
        let facts = entities.map { entity in
            KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: entity.id, predicate: .hasStatus, value: .enumeration("open"),
                qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted),
                source: .init(meetingID: Self.meeting, recordedAt: Date(timeIntervalSince1970: 1_790_000_000), evidence: [
                    .init(id: UUID(), recordingID: Self.recording, segmentIDs: ["s1"], quote: "The \(entity.name) is open.",
                          startMs: 0, endMs: 500, attributedSpeaker: "Speaker 1"),
                ]))
        }
        let large = try KnowledgeBrowserRead(meetingIDs: [Self.meeting], wiki: .init(revision: 3, entities: entities, facts: facts),
                                             meetingTitles: [Self.meeting: "Weekly review"])
        let source = ChatKnowledgeSource(read: { _, _ in large }, authorization: Self.source().authorization, remoteConsent: { _ in true })
        let first = try await run("search_knowledge", ["query": .string("portal")], source: source)
        #expect(first.content.hasPrefix("knowledge search results (best first; top 100 shown; refine the query for more):"))
        #expect(first.metrics[.searchWindowFull] == 1 && first.metrics[.searchResultLimit] == 100)
        let last = try await run("search_knowledge", ["query": .string("portal"), "offset": .number(90), "limit": .number(20)],
                                 source: source)
        #expect(last.content.contains("page: items 91–100 of 100; end"))
    }

    @Test func claimTextAndValuesAreCanonical() {
        #expect(ChatKnowledgeToolText.valueText(.number(2.5, unit: "weeks")) == "2.5 weeks")
        #expect(ChatKnowledgeToolText.valueText(.number(3, unit: nil)) == "3")
        #expect(ChatKnowledgeToolText.valueText(.boolean(false)) == "false")
        #expect(ChatKnowledgeToolText.valueText(.string("quoted")) == "quoted")
        let date = KnowledgeTemporalValue(text: "2026-11-12", precision: .day)
        #expect(date.map { ChatKnowledgeToolText.valueText(.date($0)) } == "2026-11-12")
        #expect(ChatKnowledgeTools.names.count == 13)
    }
}
