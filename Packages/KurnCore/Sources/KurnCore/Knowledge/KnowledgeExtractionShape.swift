import Foundation

/// Codable ignores unknown keys. Check the wire tree first so an invented
/// field (e.g. a model-supplied reviewState) cannot silently acquire meaning.
public enum KnowledgeExtractionShape {
    private struct ShapeRule {
        let name: String
        let required: Set<String>
        let optional: Set<String>
    }

    /// The first structural problem, described only with the schema's own key
    /// names and array indices (never a model-supplied key or value), so it is
    /// safe to log publicly and to send back in a repair request. `nil` when
    /// the shape is valid or the reply is not JSON at all.
    public static func diagnose(_ data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return "not_json" }
        let schema: [ShapeRule] = [
            ShapeRule(name: "entities", required: ["ref", "kind", "name", "aliases"], optional: []),
            ShapeRule(name: "assertions", required: ["ref", "subject", "predicate", "modality", "polarity", "claimKind",
                "authorityStatus", "confidence", "attributedToSegmentID", "evidence"],
                optional: ["object", "value", "validFrom", "validTo"]),
            ShapeRule(name: "events", required: ["ref", "entity", "assertion", "kind"], optional: ["occurredAt"])
        ]
        let rootRequired: Set<String> = ["version", "entities", "assertions", "events", "examinedSegmentIDs"]
        guard let root = raw as? [String: Any] else { return "root: not an object" }
        if let missing = rootRequired.subtracting(root.keys).sorted().first { return "root: missing \(missing)" }
        if Set(root.keys).subtracting(rootRequired).isEmpty == false { return "root: unexpected key" }
        for rule in schema {
            let (name, required, optional) = (rule.name, rule.required, rule.optional)
            guard let items = root[name] as? [Any] else { return "\(name): not an array" }
            for (index, item) in items.enumerated() {
                guard let object = item as? [String: Any] else { return "\(name)[\(index)]: not an object" }
                if let missing = required.subtracting(object.keys).sorted().first { return "\(name)[\(index)]: missing \(missing)" }
                if !Set(object.keys).subtracting(required.union(optional)).isEmpty { return "\(name)[\(index)]: unexpected key" }
                if name == "assertions", let evidence = object["evidence"] as? [Any] {
                    for (offset, entry) in evidence.enumerated() {
                        guard let ev = entry as? [String: Any], Set(["segmentIDs", "quote"]).isSubset(of: ev.keys) else {
                            return "assertions[\(index)].evidence[\(offset)]: missing segmentIDs or quote"
                        }
                    }
                }
            }
        }
        return (try? check(data)) == nil ? "nested value or date shape" : nil
    }

    static func check(_ data: Data) throws {
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) } catch { throw KnowledgeExtractionError.invalidJSON }
        let root = try object(raw, required: ["version", "entities", "assertions", "events", "examinedSegmentIDs"])
        for entity in try array(root["entities"]) {
            _ = try object(entity, required: ["ref", "kind", "name", "aliases"])
        }
        for item in try array(root["assertions"]) {
            let assertion = try object(item, required: ["ref", "subject", "predicate", "modality", "polarity", "claimKind",
                "authorityStatus", "confidence", "attributedToSegmentID", "evidence"], optional: ["object", "value", "validFrom", "validTo"])
            if let value = assertion["value"], !(value is NSNull) {
                let typed = try object(value, required: ["type", "value"], optional: ["unit", "precision"])
                let kind = typed["type"] as? String
                guard (typed["unit"] == nil || kind == "number"), (typed["precision"] == nil || kind == "date") else {
                    throw KnowledgeExtractionError.invalidSchema
                }
            }
            try date(assertion["validFrom"])
            try date(assertion["validTo"])
            for evidence in try array(assertion["evidence"]) {
                _ = try object(evidence, required: ["segmentIDs", "quote"], optional: ["startMs", "endMs"])
            }
        }
        for item in try array(root["events"]) {
            let event = try object(item, required: ["ref", "entity", "assertion", "kind"], optional: ["occurredAt"])
            try date(event["occurredAt"])
        }
    }

    private static func date(_ raw: Any?) throws {
        guard let raw, !(raw is NSNull) else { return }
        _ = try object(raw, required: ["text", "precision"])
    }

    private static func array(_ raw: Any?) throws -> [Any] {
        guard let array = raw as? [Any] else { throw KnowledgeExtractionError.invalidSchema }
        return array
    }

    private static func object(_ raw: Any, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = raw as? [String: Any], required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else { throw KnowledgeExtractionError.invalidSchema }
        return object
    }
}

extension KnowledgeExtraction {
    /// Models often wrap JSON in a Markdown fence or a sentence of prose. Keep
    /// only the outermost object so the strict decoder sees the document the
    /// model meant; nothing inside it is changed, so the validation is unchanged.
    public static func normalizedReply(_ reply: String) -> Data {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            return Data(reply.utf8)
        }
        return Data(reply[start...end].utf8)
    }
}
