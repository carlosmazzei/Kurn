import Foundation

/// Codable ignores unknown keys. Check the wire tree first so an invented
/// field (e.g. a model-supplied reviewState) cannot silently acquire meaning.
enum KnowledgeExtractionShape {
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
