import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K7.0: the Ask evaluation over the synthetic golden fixtures. The offline tests check the harness around
/// the model (fixtures to a read, the prompts, the judge's verdict and the report lines) and always run. The
/// live run asks the real model every golden question under each variant and prints `[ask-eval]` lines; it is
/// skipped unless `KURN_ASK_EVAL=1` (the `Knowledge Ask evaluation` workflow sets it with the OpenAI key), so
/// CI never calls a provider. There is no pass/fail threshold: the lines are compared between runs.
@MainActor
struct KnowledgeAskEvalTests {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let isEnabled = environment["KURN_ASK_EVAL"] == "1"

    private static let fixtureNames = ["en-moved-deadline", "en-platform-review", "en-three-contexts",
                                       "pt-corrected-transcript", "pt-provisioning-timeline"]

    // MARK: Offline

    @Test func everyFixtureBecomesAnAuthorizedReadWithItsClaims() throws {
        for name in Self.fixtureNames {
            let fixture = try KnowledgeAskEvalFiles.fixture(name)
            let read = try fixture.read(selection: nil)
            #expect(read.meetingIDs == fixture.meetingIDs && !read.meetingIDs.isEmpty)
            let claims = read.pages.flatMap { $0.sections.flatMap(\.entries) }.map(\.fact.id)
            #expect(Set(claims).count >= fixture.expected.assertions.count, "\(name): every assertion is a claim on a page")
        }
    }

    @Test func everyQuestionNamesClaimsItsFixtureHolds() throws {
        let questions = try KnowledgeAskEvalFiles.questions()
        #expect(questions.count >= 30)
        for question in questions {
            let fixture = try KnowledgeAskEvalFiles.fixture(question.fixture)
            let refs = Set(fixture.expected.assertions.map(\.ref))
            #expect(Set(question.expected).isSubset(of: refs), "\(question.id): expected refs exist")
            #expect(question.forbidden.allSatisfy { fixture.expected.mustNotAssert.indices.contains($0) }, "\(question.id): forbidden indexes exist")
            #expect(Set(question.citable).isSubset(of: fixture.segmentKeys), "\(question.id): citable segments exist")
        }
    }

    @Test func identitiesAreStableAcrossLoads() throws {
        let first = try KnowledgeAskEvalFiles.fixture("en-moved-deadline").read(selection: nil)
        let second = try KnowledgeAskEvalFiles.fixture("en-moved-deadline").read(selection: nil)
        #expect(first == second)
    }

    @Test func theKnowledgeToolsAnswerOverAFixtureAndCiteItsEvidence() async throws {
        let fixture = try KnowledgeAskEvalFiles.fixture("en-moved-deadline")
        let tools = KnowledgeAskEvalRunner.tools(for: .knowledge, fixture: fixture)
        let search = try #require(tools.first { $0.spec.name == "search_knowledge" })
        let found = try await search.execute(.object(["query": .string("contract review")]))
        #expect(!found.isError && found.content.contains("Contract review"))
        let read = try fixture.read(selection: nil)
        let entry = try #require(read.pages.flatMap { $0.sections.flatMap(\.entries) }.first)
        let evidence = try #require(entry.fact.source.evidence.first)
        let cite = try #require(tools.first { $0.spec.name == "get_evidence" })
        let cited = try await cite.execute(.object(["assertionID": .string(entry.fact.id.uuidString),
                                                    "evidenceID": .string(evidence.id.uuidString)]))
        #expect(!cited.isError)
    }

    @Test func eachVariantGetsOnlyWhatItIsMeantToSee() throws {
        let fixture = try KnowledgeAskEvalFiles.fixture("en-moved-deadline")
        let segment = try #require(fixture.sources.first?.segments.first?.text)
        let closed = KnowledgeAskEvalRunner.systemPrompt(for: .closedBook, fixture: fixture)
        let full = KnowledgeAskEvalRunner.systemPrompt(for: .fullTranscript, fixture: fixture)
        let knowledge = KnowledgeAskEvalRunner.systemPrompt(for: .knowledge, fixture: fixture)
        #expect(!closed.contains(segment) && full.contains(segment) && !knowledge.contains(segment))
        #expect(knowledge.contains("get_coverage") && !full.contains("get_coverage"))
        #expect(KnowledgeAskEvalRunner.tools(for: .closedBook, fixture: fixture).isEmpty)
        #expect(KnowledgeAskEvalRunner.tools(for: .fullTranscript, fixture: fixture).isEmpty)
        #expect(!KnowledgeAskEvalRunner.tools(for: .knowledge, fixture: fixture).isEmpty)
    }

    @Test func theJudgeSeesTheTemptingClaimsButTheModelNeverDoes() throws {
        let fixture = try KnowledgeAskEvalFiles.fixture("en-three-contexts")
        let question = try #require(try KnowledgeAskEvalFiles.questions().first { $0.fixture == fixture.id && !$0.forbidden.isEmpty })
        let table = fixture.judgeTable(expected: question.expected, forbidden: question.forbidden)
        #expect(table.contains("\(question.expected.first ?? "a1"):") && table.contains("!\(question.forbidden[0]):"))
        let tempting = fixture.expected.mustNotAssert[question.forbidden[0]].quote
        #expect(!KnowledgeAskEvalRunner.systemPrompt(for: .knowledge, fixture: fixture).contains(tempting))
        let tools = KnowledgeAskEvalRunner.tools(for: .knowledge, fixture: fixture)
        #expect(tools.allSatisfy { !$0.spec.description.contains(tempting) })
    }

    @Test func aVerdictIsReadFromFencedOrChattyReplies() throws {
        let plain = KnowledgeAskEvalRunner.verdict(from: #"{"stated":["a1"],"unsupported":1,"declined":false,"cited":["m1/s1"]}"#)
        #expect(plain == .init(stated: ["a1"], unsupported: 1, declined: false, cited: ["m1/s1"]))
        let fenced = KnowledgeAskEvalRunner.verdict(from: "Here you go:\n```json\n{\"stated\":[],\"unsupported\":0,\"declined\":true,\"cited\":[]}\n```")
        #expect(fenced?.declined == true)
        #expect(KnowledgeAskEvalRunner.verdict(from: "no json here") == nil)
        #expect(KnowledgeAskEvalRunner.verdict(from: "{not json}") == nil)
    }

    @Test func aPerfectVerdictScoresPerfectAndAForbiddenOneCounts() {
        let expectation = KnowledgeAnswerScorer.Expectation(expected: ["a1"], forbidden: ["!0"], mustRefuse: false, citable: ["m1/s1"])
        let good = KnowledgeAskEvalRunner.observation(.init(stated: ["a1"], unsupported: 0, declined: false, cited: ["m1/s1"]))
        #expect(KnowledgeAnswerScorer.score(good, against: expectation, resolvable: ["m1/s1"]).recall == 1)
        let bad = KnowledgeAskEvalRunner.observation(.init(stated: ["!0"], unsupported: 0, declined: false, cited: []))
        #expect(KnowledgeAnswerScorer.score(bad, against: expectation, resolvable: ["m1/s1"]).forbiddenStated == 1)
    }

    @Test func reportLinesCarryScoresAndTokensButNoContent() {
        let expectation = KnowledgeAnswerScorer.Expectation(expected: ["a1", "a2"], forbidden: [], mustRefuse: false, citable: ["m1/s1"])
        let score = KnowledgeAnswerScorer.score(.init(stated: ["a1"], refused: false, cited: ["m1/s1"]), against: expectation,
                                                resolvable: ["m1/s1"])
        let usage = AgentUsage(inputTokens: 10, outputTokens: 5)
        let observation = KnowledgeAskEvalRunner.Observation(variant: .knowledge, questionID: "q1", kind: "fact", score: score,
                                                             toolCalls: 3, stop: "completed", answerTokens: usage, judgeTokens: usage)
        let line = KnowledgeAskEvalRunner.line(observation)
        #expect(line.hasPrefix("[ask-eval] variant=knowledge question=q1 kind=fact precision=1.00 recall=0.50"))
        #expect(line.contains("tool_calls=3") && line.contains("input_tokens=10") && line.contains("cites_grounded=false"))
        let summary = KnowledgeAskEvalRunner.summaryLine(.knowledge, label: "all", [observation])
        #expect(summary.contains("summary variant=knowledge group=all questions=1"))
    }

    @Test func workflowInputsAreReadStrictlyAndBlankMeansAll() throws {
        #expect(try KnowledgeAskEvalRunner.variants(from: "") == KnowledgeAskEvalRunner.Variant.allCases)
        #expect(try KnowledgeAskEvalRunner.variants(from: " knowledge , closed_book ") == [.knowledge, .closedBook])
        #expect(throws: KnowledgeAskEvalRunner.EvalError.invalidInput("variants")) {
            try KnowledgeAskEvalRunner.variants(from: "knowledge,knowlege")
        }
        #expect(try KnowledgeAskEvalRunner.limit(from: "  ") == nil)
        #expect(try KnowledgeAskEvalRunner.limit(from: "3") == 3)
        for bad in ["0", "-2", "three", "2.5"] {
            #expect(throws: KnowledgeAskEvalRunner.EvalError.invalidInput("limit")) { try KnowledgeAskEvalRunner.limit(from: bad) }
        }
    }

    @Test func coverageIsAvailableAndEveryClaimNeedsOneOfItsOwnSegments() async throws {
        let fixture = try KnowledgeAskEvalFiles.fixture("en-moved-deadline")
        let coverage = try #require(KnowledgeAskEvalRunner.tools(for: .knowledge, fixture: fixture).first { $0.spec.name == "get_coverage" })
        let output = try await coverage.execute(.object([:]))
        #expect(!output.isError && output.content.contains("complete: yes"))
        let question = try #require(try KnowledgeAskEvalFiles.questions().first { $0.fixture == fixture.id && $0.expected.count > 1 })
        let evidence = fixture.evidenceSegments(for: question.expected)
        #expect(Set(evidence.keys) == Set(question.expected) && evidence.values.allSatisfy { !$0.isEmpty })
    }

    @Test func theTranscriptGivesEachSegmentItsTimeSoACitedMomentResolves() throws {
        let fixture = try KnowledgeAskEvalFiles.fixture("en-moved-deadline")
        #expect(fixture.transcriptText.contains("[m1/s1 at 0:00]"))
        #expect(KnowledgeAskEvalFixture.clock(125_000) == "2:05")
    }

    // MARK: Live

    /// Every golden question, each variant. `KURN_ASK_EVAL_LIMIT` caps the questions (a small first run
    /// shows what the full one costs), `KURN_ASK_EVAL_VARIANTS` picks variants, `KURN_ASK_EVAL_MODEL` and
    /// `KURN_ASK_EVAL_JUDGE_MODEL` the models (the provider's default when blank).
    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(120)))
    func theModelAnswersTheGoldenQuestions() async throws {
        guard let key = Self.environment["OPENAI_API_KEY"], !key.isEmpty else {
            print("[ask-eval] skipped=no_key")
            return
        }
        func named(_ variable: String) -> String {
            Self.environment[variable].flatMap { $0.isEmpty ? nil : $0 } ?? AIProvider.openAI.defaultModel
        }
        let target = LiveProviderSmokeTests.targets[0]
        let model = named("KURN_ASK_EVAL_MODEL"), judgeModel = named("KURN_ASK_EVAL_JUDGE_MODEL")
        let runner = KnowledgeAskEvalRunner(model: LiveProviderSmokeTests.client(target, key: key, model: model),
                                            judge: LiveProviderSmokeTests.client(target, key: key, model: judgeModel))
        // Invalid inputs are refused here, before the first paid call.
        let variants = try KnowledgeAskEvalRunner.variants(from: Self.environment["KURN_ASK_EVAL_VARIANTS"] ?? "")
        var questions = try KnowledgeAskEvalFiles.questions()
        if let limit = try KnowledgeAskEvalRunner.limit(from: Self.environment["KURN_ASK_EVAL_LIMIT"] ?? "") {
            questions = Array(questions.prefix(limit))
        }
        print("[ask-eval] model=\(model) judge=\(judgeModel) questions=\(questions.count) variants=\(variants.map(\.rawValue).joined(separator: ","))")
        var scored: [KnowledgeAskEvalRunner.Variant: [KnowledgeAskEvalRunner.Observation]] = [:]
        for variant in variants {
            var observations: [KnowledgeAskEvalRunner.Observation] = []
            for question in questions {
                let fixture = try KnowledgeAskEvalFiles.fixture(question.fixture)
                do {
                    let observation = try await runner.run(question, variant: variant, fixture: fixture)
                    observations.append(observation)
                    print(KnowledgeAskEvalRunner.line(observation))
                } catch KnowledgeAskEvalRunner.EvalError.unreadableVerdict {
                    print("[ask-eval] variant=\(variant.rawValue) question=\(question.id) failed=judge_unreadable")
                } catch {
                    print("[ask-eval] variant=\(variant.rawValue) question=\(question.id) failed=\(error.publicLogCode)")
                }
            }
            scored[variant] = observations
            print(KnowledgeAskEvalRunner.summaryLine(variant, label: "all", attempted: questions.count, observations))
            for kind in Set(observations.map(\.kind)).sorted() {
                print(KnowledgeAskEvalRunner.summaryLine(variant, label: kind, observations.filter { $0.kind == kind }))
            }
        }
        // A failure leaves a question out of one variant's average: compare variants on what every one of them scored.
        let common = variants.map { Set(scored[$0, default: []].map(\.questionID)) }.reduce(Set(questions.map(\.id))) { $0.intersection($1) }
        for variant in variants {
            print(KnowledgeAskEvalRunner.summaryLine(variant, label: "common", attempted: questions.count,
                                                     scored[variant, default: []].filter { common.contains($0.questionID) }))
        }
    }
}
