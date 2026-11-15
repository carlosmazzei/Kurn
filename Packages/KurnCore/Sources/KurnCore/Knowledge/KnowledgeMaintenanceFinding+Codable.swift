import Foundation

extension KnowledgeMaintenanceFinding: Codable {
    private enum CodingKeys: String, CodingKey { case id, code, subjects, recommendation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Code.self, forKey: .code)
        let subjects = try container.decode([Reference].self, forKey: .subjects)
        self.init(code: code, subjects: subjects)
        guard subjects == self.subjects, try container.decode(String.self, forKey: .id) == id,
              try container.decode(Recommendation.self, forKey: .recommendation) == recommendation else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Inconsistent maintenance finding")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(code, forKey: .code)
        try container.encode(subjects, forKey: .subjects)
        try container.encode(recommendation, forKey: .recommendation)
    }
}
