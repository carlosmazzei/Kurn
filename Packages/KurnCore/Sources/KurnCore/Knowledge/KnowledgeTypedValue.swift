//
//  KnowledgeTypedValue.swift
//  KurnCore
//
//  The object of a non-relational assertion (spec §5.1): a string, a number
//  with an optional unit, a boolean, a date at its stated precision, or a value
//  of a closed enumeration such as a status. The wire form is the extraction
//  contract's `{"type": …, "value": "…", "unit"?: …, "precision"?: …}` with the
//  value always a string, so a model never has to choose a JSON type.
//

import Foundation

public enum KnowledgeValueType: String, Codable, Sendable, CaseIterable {
    case string, number, boolean, date
    case enumeration = "enum"
}

public enum KnowledgeTypedValue: Hashable, Sendable {
    case string(String)
    case number(Double, unit: String?)
    case boolean(Bool)
    case date(KnowledgeTemporalValue)
    case enumeration(String)

    public var type: KnowledgeValueType {
        switch self {
        case .string: .string
        case .number: .number
        case .boolean: .boolean
        case .date: .date
        case .enumeration: .enumeration
        }
    }
}

extension KnowledgeTypedValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value, unit, precision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(KnowledgeValueType.self, forKey: .type)
        let text = try container.decode(String.self, forKey: .value)
        func invalid(_ reason: String) -> DecodingError {
            .dataCorruptedError(forKey: .value, in: container, debugDescription: reason)
        }
        switch type {
        case .string:
            guard !text.isEmpty else { throw invalid("empty string value") }
            self = .string(text)
        case .number:
            guard let number = Double(text), number.isFinite else { throw invalid("not a finite number") }
            self = .number(number, unit: try container.decodeIfPresent(String.self, forKey: .unit))
        case .boolean:
            guard let flag = Bool(text) else { throw invalid("not true or false") }
            self = .boolean(flag)
        case .date:
            let precision = try container.decode(KnowledgeTemporalPrecision.self, forKey: .precision)
            guard let date = KnowledgeTemporalValue(text: text, precision: precision) else {
                throw invalid("date does not match its precision")
            }
            self = .date(date)
        case .enumeration:
            guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { throw invalid("not an enumeration case") }
            self = .enumeration(text)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case let .string(text), let .enumeration(text):
            try container.encode(text, forKey: .value)
        case let .number(number, unit):
            let text = number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
            try container.encode(text, forKey: .value)
            try container.encodeIfPresent(unit, forKey: .unit)
        case let .boolean(flag):
            try container.encode(String(flag), forKey: .value)
        case let .date(date):
            try container.encode(date.text, forKey: .value)
            try container.encode(date.precision, forKey: .precision)
        }
    }
}
