import Foundation
import Testing
@testable import AgentHarness

/// The remote catalog's format, its strict reading, and the overlay over the bundled catalogs.
/// Serialized because the overlay is process-wide; every installed model ID is a test-only name,
/// so suites running beside it see only the bundled facts.
@Suite(.serialized)
struct ModelCatalogDocumentTests {
    static let version = ModelCatalogDocument.bundledVersion

    static func json(version: String = version, format: String = "kurn.model-catalog", schema: Int = 1,
                     models: String) -> Data {
        Data(#"{"format":"\#(format)","schema":\#(schema),"version":"\#(version)","models":{\#(models)}}"#.utf8)
    }

    static func rejection(_ data: Data) -> ModelCatalogDocument.ValidationError? {
        do {
            _ = try ModelCatalogDocument.decode(data)
            return nil
        } catch let error as ModelCatalogDocument.ValidationError {
            return error
        } catch {
            return nil
        }
    }

    @Test func aDocumentReadsItsEntries() throws {
        let document = try ModelCatalogDocument.decode(Self.json(models: #"""
            "kurn-test-a":{"context":300000,"maxOutput":9000,"limit":"input","tools":"supported","reasoning":"unknown",
            "imageInput":"unsupported","price":{"input":2,"output":8,"cacheRead":0.1}},"kurn-test-b":{}
            """#))
        let entry = try #require(document.entry(for: "vendor/kurn-test-a"))
        #expect(entry.contextTokens == 300_000 && entry.maxOutputTokens == 9_000 && entry.limitKind == .input)
        #expect(entry.tools == .supported && entry.reasoning == .unknown && entry.imageInput == .unsupported)
        #expect(entry.pricing == .init(inputPerMillion: 2, outputPerMillion: 8, cacheRead: 0.1, cacheWrite: 1))
        #expect(document.entry(for: "kurn-test-a-2026-01-31") == entry)
        #expect(document.entry(for: "kurn-test-a-preview") == nil)
        #expect(document.entry(for: "kurn-test-b")?.contextTokens == nil)
        #expect(document.provenance == "remote-\(Self.version)")
    }

    @Test func anythingOutsideTheRulesIsRefusedWhole() {
        #expect(Self.rejection(Data("not json".utf8)) == .malformed)
        #expect(Self.rejection(Self.json(format: "other", models: "")) == .unsupportedFormat)
        #expect(Self.rejection(Self.json(schema: 2, models: "")) == .unsupportedSchema)
        #expect(Self.rejection(Self.json(version: "14/11/2026", models: "")) == .invalidVersion)
        #expect(Self.rejection(Self.json(models: #""gpt 5":{}"#)) == .invalidModelID("gpt 5"))
        #expect(Self.rejection(Self.json(models: #""a/b":{}"#)) == .invalidModelID("a/b"))
        #expect(Self.rejection(Self.json(models: #""GPT-5":{}"#)) == .invalidModelID("GPT-5"))
        #expect(Self.rejection(Self.json(models: #""m":{"context":10}"#)) == .outOfRange(model: "m", field: "context"))
        #expect(Self.rejection(Self.json(models: #""m":{"context":8000,"maxOutput":9000}"#))
            == .outOfRange(model: "m", field: "maxOutput"))
        #expect(Self.rejection(Self.json(models: #""m":{"limit":"output"}"#)) == .outOfRange(model: "m", field: "limit"))
        #expect(Self.rejection(Self.json(models: #""m":{"tools":"maybe"}"#)) == .outOfRange(model: "m", field: "tools"))
        #expect(Self.rejection(Self.json(models: #""m":{"price":{"input":-1,"output":1}}"#))
            == .outOfRange(model: "m", field: "price.input"))
        #expect(Self.rejection(Self.json(models: #""m":{"price":{"input":1,"output":1,"cacheWrite":50}}"#))
            == .outOfRange(model: "m", field: "price.cacheWrite"))
        #expect(Self.rejection(Data(count: ModelCatalogDocument.maxBytes + 1)) == .tooLarge)
        let many = (0...ModelCatalogDocument.maxModels).map { #""m\#($0)":{}"# }.joined(separator: ",")
        #expect(Self.rejection(Self.json(models: many)) == .tooManyModels)
    }

    @Test func anInstalledDocumentOverridesTheBundledFactsItStates() throws {
        defer { ModelCatalogOverlay.install(nil) }
        let document = try ModelCatalogDocument.decode(Self.json(models: #"""
            "kurn-test-window":{"context":300000,"maxOutput":9000,"tools":"supported","reasoning":"unsupported"},
            "kurn-test-output-only":{"maxOutput":4000},"claude-opus-kurn-test":{"reasoning":"supported"},
            "gpt-4o-kurn-test":{"maxOutput":2000},"kurn-test-context-only":{"context":200000}
            """#))
        #expect(ModelCatalogOverlay.install(document))

        let resolution = ModelContextWindows.resolve(model: "kurn-test-window")
        #expect(resolution.contextWindowTokens == 300_000)
        #expect(resolution.maxOutputTokens == 9_000)
        #expect(resolution.catalogVersion == document.provenance)
        #expect(ModelContextWindows.knownWindow(forModel: "kurn-test-window") == 300_000)
        // An output limit with no window anywhere is not a window, but it still bounds the output.
        #expect(ModelContextCatalog.entry(for: "kurn-test-output-only") == nil)
        let unknown = ModelContextWindows.resolve(model: "kurn-test-output-only")
        #expect(unknown.source == .fixedFallback && unknown.maxOutputTokens == 4_000)
        // A published output limit applies to a window from the family table or from the provider.
        let family = ModelContextWindows.resolve(model: "gpt-4o-kurn-test")
        #expect(family.contextWindowTokens == 128_000 && family.maxOutputTokens == 2_000)
        let reported = AgentModelLimits(contextWindowTokens: 90_000, maxOutputTokens: nil)
        let api = ModelContextWindows.resolve(model: "gpt-4o-kurn-test", reported: reported)
        #expect(api.source == .api && api.contextWindowTokens == 90_000 && api.maxOutputTokens == 2_000)
        // A window alone says nothing about how much the model writes.
        let contextOnly = ModelContextWindows.resolve(model: "kurn-test-context-only")
        #expect(contextOnly.contextWindowTokens == 200_000 && contextOnly.maxOutputTokens == nil)

        let capabilities = ModelCapabilityCatalog.resolve(api: "openAI", model: "kurn-test-window")
        #expect(capabilities.tools == .supported && capabilities.reasoning == .unsupported && capabilities.imageInput == .unknown)
        #expect(capabilities.source == .catalog && capabilities.catalogVersion == document.provenance)
        // A fact the document leaves out keeps the family rule's.
        let claude = ModelCapabilityCatalog.resolve(api: "anthropic", model: "claude-opus-kurn-test")
        #expect(claude.reasoning == .supported && claude.tools == .supported && claude.imageInput == .supported)

        // Models it does not list are untouched.
        #expect(ModelContextWindows.resolve(model: "gpt-5").catalogVersion == ModelContextCatalog.version)
        #expect(ModelCapabilityCatalog.resolve(api: "openAI", model: "gpt-5").catalogVersion == ModelCapabilityCatalog.version)

        ModelCatalogOverlay.install(nil)
        #expect(ModelContextCatalog.entry(for: "kurn-test-window") == nil)
    }

    @Test func anOlderOrFutureDocumentIsNotInstalled() throws {
        defer { ModelCatalogOverlay.install(nil) }
        let older = try ModelCatalogDocument.decode(Self.json(version: "2020-01-01", models: ""))
        #expect(!ModelCatalogOverlay.install(older))
        let future = try ModelCatalogDocument.decode(Self.json(version: "2999-01-01", models: ""))
        #expect(!ModelCatalogOverlay.install(future))
        let current = try ModelCatalogDocument.decode(Self.json(version: "2099-01-01", models: ""))
        let longAfter = try #require(ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
        #expect(ModelCatalogOverlay.install(current, now: longAfter))
        let earlier = try ModelCatalogDocument.decode(Self.json(models: ""))
        #expect(!ModelCatalogOverlay.install(earlier, now: longAfter))
        #expect(ModelCatalogOverlay.current?.version == "2099-01-01")
    }

    /// The document published in the repository reads, and states nothing that contradicts the
    /// bundled catalogs it was written from.
    @Test func thePublishedCatalogAgreesWithTheBundledOne() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../../../catalog/model-catalog-v1.json").standardizedFileURL
        let document = try ModelCatalogDocument.decode(try Data(contentsOf: url))
        #expect(document.version >= ModelCatalogDocument.bundledVersion)
        #expect(!document.models.isEmpty)
        for (model, entry) in document.models {
            if let bundled = ModelContextCatalog.bundledEntry(for: model) {
                #expect(entry.contextTokens == bundled.tokens, "\(model)")
                #expect(entry.maxOutputTokens == bundled.maxOutputTokens, "\(model)")
                #expect(entry.limitKind == bundled.limitKind, "\(model)")
            }
            if let facts = ModelCapabilityCatalog.facts(for: model), facts.source == .catalog {
                #expect(entry.tools == facts.facts.tools && entry.reasoning == facts.facts.reasoning
                        && entry.imageInput == facts.facts.imageInput, "\(model)")
            }
        }
    }
}
