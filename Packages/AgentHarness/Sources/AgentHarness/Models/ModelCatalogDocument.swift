import Foundation

/// A model catalog delivered as data (`kurn.model-catalog`, schema 1): per exact model ID, the
/// capacity, capabilities and list prices the app otherwise compiles in. It lets reviewed facts
/// reach the app between releases.
///
/// It is read strictly: a document of another format or schema, a malformed version, too many
/// models, an ID outside the allowed characters, or a number outside its plausible range is
/// refused whole rather than partly applied. It can only change what the app estimates (context
/// window, output limit, capabilities, cost); it names no endpoint and carries nothing that is sent.
public struct ModelCatalogDocument: Sendable, Equatable {
    public static let format = "kurn.model-catalog"
    public static let schema = 1
    public static let maxBytes = 256 * 1_024
    public static let maxModels = 2_000
    static let maxIDLength = 128
    static let tokenRange = 1_024...20_000_000
    static let priceRange = 0.0...10_000.0
    static let multiplierRange = 0.0...10.0

    public struct Pricing: Sendable, Equatable {
        /// USD per million input and output tokens.
        public let inputPerMillion: Double
        public let outputPerMillion: Double
        /// Cache reads and writes as multiples of the input rate.
        public let cacheRead: Double
        public let cacheWrite: Double
    }

    public struct Entry: Sendable, Equatable {
        public let contextTokens: Int?
        public let maxOutputTokens: Int?
        public let limitKind: AgentContextResolution.LimitKind?
        public let tools: AgentModelCapabilities.Support?
        public let reasoning: AgentModelCapabilities.Support?
        public let imageInput: AgentModelCapabilities.Support?
        public let pricing: Pricing?
    }

    public enum ValidationError: Error, Equatable {
        case tooLarge, malformed, unsupportedFormat, unsupportedSchema, invalidVersion, tooManyModels
        case invalidModelID(String)
        case outOfRange(model: String, field: String)
    }

    /// The day the facts were reviewed (`yyyy-MM-dd`); later documents supersede earlier ones.
    public let version: String
    /// Keyed by lowercase model ID (an uppercase one is refused), without a vendor prefix.
    public let models: [String: Entry]

    /// The version recorded as a run's `catalogVersion` when one of these facts was used.
    public var provenance: String { "remote-\(version)" }

    /// The newest of the bundled catalogs' versions: a document older than this has nothing the
    /// app does not already know better.
    public static var bundledVersion: String { max(ModelContextCatalog.version, ModelCapabilityCatalog.version) }

    /// Reads and validates `data`, or throws the first rule it breaks.
    public static func decode(_ data: Data) throws -> ModelCatalogDocument {
        guard data.count <= maxBytes else { throw ValidationError.tooLarge }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) } catch { throw ValidationError.malformed }
        guard wire.format == format else { throw ValidationError.unsupportedFormat }
        guard wire.schema == schema else { throw ValidationError.unsupportedSchema }
        guard isVersion(wire.version) else { throw ValidationError.invalidVersion }
        guard wire.models.count <= maxModels else { throw ValidationError.tooManyModels }
        var models: [String: Entry] = [:]
        for (id, value) in wire.models {
            guard isModelID(id) else { throw ValidationError.invalidModelID(id) }
            models[id] = try value.entry(model: id)
        }
        return ModelCatalogDocument(version: wire.version, models: models)
    }

    /// The entry for `model`, matched like the bundled catalogs: the last path component, lowercased,
    /// exactly or as a documented date-shaped snapshot (`-yyyy-mm-dd`) of an exact entry.
    public func entry(for model: String) -> Entry? {
        let name = model.split(separator: "/").last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !name.isEmpty else { return nil }
        if let entry = models[name] { return entry }
        guard name.count > 11 else { return nil }
        let suffix = String(name.suffix(11))
        guard suffix.range(of: #"^-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return models[String(name.dropLast(11))]
    }

    static func isVersion(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    static func isModelID(_ value: String) -> Bool {
        guard (1...maxIDLength).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || ".-_:".unicodeScalars.contains(scalar)
        }
    }

    private struct Wire: Decodable {
        let format: String
        let schema: Int
        let version: String
        let models: [String: WireEntry]
    }

    private struct WireEntry: Decodable {
        struct Price: Decodable {
            let input: Double
            let output: Double
            let cacheRead: Double?
            let cacheWrite: Double?
        }
        let context: Int?
        let maxOutput: Int?
        let limit: String?
        let tools: String?
        let reasoning: String?
        let imageInput: String?
        let price: Price?

        func entry(model: String) throws -> Entry {
            func fail(_ field: String) -> ValidationError { .outOfRange(model: model, field: field) }
            if let context, !ModelCatalogDocument.tokenRange.contains(context) { throw fail("context") }
            if let maxOutput {
                guard maxOutput >= 1, maxOutput <= (context ?? ModelCatalogDocument.tokenRange.upperBound) else {
                    throw fail("maxOutput")
                }
            }
            func parse<Value: RawRepresentable>(_ raw: String?, _ field: String) throws -> Value? where Value.RawValue == String {
                guard let raw else { return nil }
                guard let value = Value(rawValue: raw) else { throw fail(field) }
                return value
            }
            let pricing: Pricing? = try price.map { price in
                let read = price.cacheRead ?? 1, write = price.cacheWrite ?? 1
                guard ModelCatalogDocument.priceRange.contains(price.input), price.input.isFinite else { throw fail("price.input") }
                guard ModelCatalogDocument.priceRange.contains(price.output), price.output.isFinite else { throw fail("price.output") }
                guard ModelCatalogDocument.multiplierRange.contains(read) else { throw fail("price.cacheRead") }
                guard ModelCatalogDocument.multiplierRange.contains(write) else { throw fail("price.cacheWrite") }
                return Pricing(inputPerMillion: price.input, outputPerMillion: price.output, cacheRead: read, cacheWrite: write)
            }
            return Entry(contextTokens: context, maxOutputTokens: maxOutput, limitKind: try parse(limit, "limit"),
                         tools: try parse(tools, "tools"), reasoning: try parse(reasoning, "reasoning"),
                         imageInput: try parse(imageInput, "imageInput"), pricing: pricing)
        }
    }
}

/// The catalog document the process applies over the bundled catalogs, installed by the host once
/// it has one it trusts. Facts it states win; facts it leaves out fall back to the bundled ones.
public enum ModelCatalogOverlay {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var document: ModelCatalogDocument?
    }

    private static let box = Box()

    public static var current: ModelCatalogDocument? {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.document
    }

    /// Applies `document`, or removes the overlay with nil. A document older than the bundled
    /// catalogs or than the one already applied is refused (returns false), and so is one dated more
    /// than two days after `now`, which would otherwise shut out every later correction.
    @discardableResult
    public static func install(_ document: ModelCatalogDocument?, now: Date = Date()) -> Bool {
        box.lock.lock()
        defer { box.lock.unlock() }
        guard let document else {
            box.document = nil
            return true
        }
        guard document.version >= ModelCatalogDocument.bundledVersion,
              document.version >= box.document?.version ?? "",
              document.version <= latestAcceptableVersion(now: now) else { return false }
        box.document = document
        return true
    }

    static func latestAcceptableVersion(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now.addingTimeInterval(2 * 24 * 60 * 60))
    }

    /// The applied entry for `model` with the document's provenance, if any.
    public static func entry(for model: String) -> (entry: ModelCatalogDocument.Entry, provenance: String)? {
        guard let document = current, let entry = document.entry(for: model) else { return nil }
        return (entry, document.provenance)
    }
}
