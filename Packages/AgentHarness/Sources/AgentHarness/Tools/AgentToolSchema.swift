import Foundation

public enum AgentToolSchemaError: Error, Sendable, Equatable {
    case invalidSchema, invalidArguments, duplicateName, invalidName
}

/// Deliberately small, non-coercing JSON Schema profile. Unknown keywords fail registration.
public struct AgentToolSchema: Sendable {
    private let schema: JSONValue

    public init(_ schema: JSONValue) throws {
        var remaining = 4_096
        try Self.check(schema, depth: 0, remaining: &remaining)
        guard case .object(let fields) = schema, fields["type"] == .string("object") else {
            throw AgentToolSchemaError.invalidSchema
        }
        self.schema = schema
    }

    public func validate(_ arguments: JSONValue) throws {
        guard Self.matches(arguments, schema: schema) else { throw AgentToolSchemaError.invalidArguments }
    }

    private static func check(_ schema: JSONValue, depth: Int, remaining: inout Int) throws {
        remaining -= 1
        guard depth <= 32, remaining >= 0, case .object(let fields) = schema,
              case .string(let type) = fields["type"] else { throw AgentToolSchemaError.invalidSchema }
        let common: Set<String> = ["type", "description", "enum"]
        let keywords: Set<String>
        switch type {
        case "object": keywords = ["properties", "required", "additionalProperties"]
        case "array": keywords = ["items", "minItems", "maxItems"]
        case "string": keywords = ["format", "minLength", "maxLength"]
        case "number", "integer": keywords = ["minimum", "maximum"]
        case "boolean", "null": keywords = []
        default: throw AgentToolSchemaError.invalidSchema
        }
        guard Set(fields.keys).isSubset(of: common.union(keywords)),
              fields["description"].map({ if case .string = $0 { return true }; return false }) ?? true else {
            throw AgentToolSchemaError.invalidSchema
        }
        if type == "object" { try checkObject(fields, depth: depth, remaining: &remaining) }
        if type == "array" {
            guard let items = fields["items"] else { throw AgentToolSchemaError.invalidSchema }
            try check(items, depth: depth + 1, remaining: &remaining)
        }
        if let format = fields["format"], format != .string("uuid") { throw AgentToolSchemaError.invalidSchema }
        try checkBounds(fields)
        try checkEnum(fields)
    }

    private static func checkObject(_ fields: [String: JSONValue], depth: Int, remaining: inout Int) throws {
        guard case .object(let properties) = fields["properties"],
              case .bool = fields["additionalProperties"] else { throw AgentToolSchemaError.invalidSchema }
        let required = fields["required"] ?? .array([])
        guard case .array(let names) = required else { throw AgentToolSchemaError.invalidSchema }
        let strings = names.compactMap { if case .string(let name) = $0 { return name }; return nil }
        guard strings.count == names.count, Set(strings).count == strings.count,
              Set(strings).isSubset(of: Set(properties.keys)) else { throw AgentToolSchemaError.invalidSchema }
        for child in properties.values { try check(child, depth: depth + 1, remaining: &remaining) }
    }

    private static func checkBounds(_ fields: [String: JSONValue]) throws {
        for (lower, upper) in [("minLength", "maxLength"), ("minItems", "maxItems"), ("minimum", "maximum")] {
            for key in [lower, upper] where fields[key] != nil {
                guard case .number(let number) = fields[key], number.isFinite,
                      key == "minimum" || key == "maximum" || (number >= 0 && number.rounded() == number) else {
                    throw AgentToolSchemaError.invalidSchema
                }
            }
            if case .number(let min) = fields[lower], case .number(let max) = fields[upper], min > max {
                throw AgentToolSchemaError.invalidSchema
            }
        }
    }

    private static func checkEnum(_ fields: [String: JSONValue]) throws {
        if let enumeration = fields["enum"] {
            guard case .array(let values) = enumeration, !values.isEmpty else { throw AgentToolSchemaError.invalidSchema }
            var base = fields; base.removeValue(forKey: "enum")
            for (index, value) in values.enumerated() {
                guard !values.prefix(index).contains(value), matches(value, schema: .object(base)) else {
                    throw AgentToolSchemaError.invalidSchema
                }
            }
        }
    }

    private static func matches(_ value: JSONValue, schema: JSONValue) -> Bool {
        guard case .object(let fields) = schema, case .string(let type) = fields["type"] else { return false }
        if case .array(let values) = fields["enum"], !values.contains(value) { return false }
        switch (type, value) {
        case ("object", .object(let object)): return matchesObject(object, fields: fields)
        case ("array", .array(let array)):
            guard let items = fields["items"], bounded(Double(array.count), fields, "minItems", "maxItems") else { return false }
            return array.allSatisfy { matches($0, schema: items) }
        case ("string", .string(let string)):
            return bounded(Double(string.unicodeScalars.count), fields, "minLength", "maxLength")
                && (fields["format"] == nil || UUID(uuidString: string) != nil)
        case ("number", .number(let number)), ("integer", .number(let number)):
            return number.isFinite && (type != "integer" || number.rounded() == number)
                && bounded(number, fields, "minimum", "maximum")
        case ("boolean", .bool), ("null", .null): return true
        default: return false
        }
    }

    private static func matchesObject(_ object: [String: JSONValue], fields: [String: JSONValue]) -> Bool {
        guard case .object(let properties) = fields["properties"] else { return false }
        if fields["additionalProperties"] == .bool(false), !Set(object.keys).isSubset(of: Set(properties.keys)) { return false }
        if case .array(let required) = fields["required"], !required.allSatisfy({
            if case .string(let key) = $0 { return object[key] != nil }; return false
        }) { return false }
        return object.allSatisfy { key, value in properties[key].map { matches(value, schema: $0) } ?? true }
    }

    private static func bounded(_ value: Double, _ fields: [String: JSONValue], _ lower: String, _ upper: String) -> Bool {
        if case .number(let min) = fields[lower], value < min { return false }
        if case .number(let max) = fields[upper], value > max { return false }
        return true
    }
}

public struct AgentToolRegistry: Sendable {
    private let tools: [String: AgentTool]
    private let schemas: [String: AgentToolSchema]

    public init(_ bundled: [AgentTool]) throws {
        var tools: [String: AgentTool] = [:]
        var schemas: [String: AgentToolSchema] = [:]
        for tool in bundled {
            let name = tool.spec.name
            guard !name.isEmpty, name.utf8.count <= 64,
                  name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                throw AgentToolSchemaError.invalidName
            }
            guard tools[name] == nil else { throw AgentToolSchemaError.duplicateName }
            schemas[name] = try AgentToolSchema(tool.spec.inputSchema)
            tools[name] = tool
        }
        self.tools = tools; self.schemas = schemas
    }

    public func tool(named name: String) -> AgentTool? { tools[name] }
    public func validate(_ arguments: JSONValue, for name: String) throws {
        guard let schema = schemas[name] else { throw AgentToolSchemaError.invalidName }
        try schema.validate(arguments)
    }
}
