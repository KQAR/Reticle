import Foundation

/// A small, dependency-free JSON Schema (draft 2020-12) validator covering
/// exactly the keywords the `reticle-protocol/schema/*.json` files use:
/// `type`, `required`, `properties`, `additionalProperties`, `$ref`/`$defs`,
/// `enum`, `const`, `oneOf`, `allOf`, `if`/`then`, `minimum`, `minLength`,
/// `pattern`, and `items`.
///
/// Test-only, and deliberately hand-rolled rather than pulling a third-party
/// validator: the Kotlin side validates the same schemas with networknt, but
/// the Swift side had only field-name comparison, so type/enum/nesting drift
/// went unnoticed. This closes that gap while matching the repo's no-heavy-
/// dependency posture. It is NOT a general-purpose validator — remote `$ref`,
/// `$anchor`, `dependentSchemas`, `patternProperties`, etc. are unsupported and
/// would throw `unsupportedKeyword` rather than silently pass.
enum JSONSchemaValidator {
    /// Validates `instanceData` (raw JSON bytes) against the schema at
    /// `schemaURL`. Returns the list of validation errors — empty means valid.
    static func validate(instanceData: Data, schemaURL: URL) throws -> [String] {
        let schemaAny = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL))
        let instanceAny = try JSONSerialization.jsonObject(with: instanceData)
        let root = JSONValue(schemaAny)
        var ctx = Context(root: root)
        ctx.validate(JSONValue(instanceAny), against: root, path: "$")
        return ctx.errors
    }

    // MARK: - JSON value model

    /// A parsed JSON value that distinguishes integer/real/bool cleanly, which
    /// `NSNumber` alone does not (a bool and 1 share a class). This is what lets
    /// `type: "integer"` reject a `3.0` and `type: "boolean"` reject a `1`.
    indirect enum JSONValue {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case integer(Int64)
        case double(Double)
        case bool(Bool)
        case null

        init(_ any: Any) {
            switch any {
            case is NSNull:
                self = .null
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID():
                self = .bool(n.boolValue)
            case let n as NSNumber:
                self = CFNumberIsFloatType(n) ? .double(n.doubleValue) : .integer(n.int64Value)
            case let s as String:
                self = .string(s)
            case let a as [Any]:
                self = .array(a.map(JSONValue.init))
            case let o as [String: Any]:
                self = .object(o.mapValues(JSONValue.init))
            default:
                self = .null
            }
        }

        var typeName: String {
            switch self {
            case .object: "object"
            case .array: "array"
            case .string: "string"
            case .integer: "integer"
            case .double: "number"
            case .bool: "boolean"
            case .null: "null"
            }
        }
    }

    enum SchemaError: Error, CustomStringConvertible {
        case unsupportedKeyword(String)
        case badRef(String)
        var description: String {
            switch self {
            case .unsupportedKeyword(let k): "unsupported schema keyword: \(k)"
            case .badRef(let r): "unresolvable $ref: \(r)"
            }
        }
    }

    // MARK: - Validation

    private struct Context {
        let root: JSONValue
        var errors: [String] = []

        mutating func fail(_ path: String, _ message: String) {
            errors.append("\(path): \(message)")
        }

        /// Validate `instance` against `schema`. A boolean schema (`true`/`false`)
        /// is legal in 2020-12; `additionalProperties: false` uses it.
        mutating func validate(_ instance: JSONValue, against schema: JSONValue, path: String) {
            switch schema {
            case .bool(let ok):
                if !ok { fail(path, "schema `false` forbids any value") }
                return
            case .object(let s):
                validateObject(instance, schema: s, path: path)
            default:
                fail(path, "schema node is neither an object nor a boolean")
            }
        }

        private mutating func validateObject(_ instance: JSONValue, schema: [String: JSONValue], path: String) {
            if let refValue = schema["$ref"] {
                guard case .string(let ref) = refValue else {
                    fail(path, "$ref must be a string"); return
                }
                guard let resolved = resolve(ref) else {
                    errors.append("\(path): unresolvable $ref \(ref)"); return
                }
                validate(instance, against: resolved, path: path)
                // The reticle schemas never combine $ref with sibling keywords,
                // so following the ref alone is complete for them.
                return
            }

            for (keyword, value) in schema {
                switch keyword {
                case "$schema", "$id", "title", "description", "$defs", "then", "else":
                    continue // metadata or handled elsewhere
                case "type":
                    checkType(instance, typeSchema: value, path: path)
                case "enum":
                    checkEnum(instance, value, path: path)
                case "const":
                    if !instance.jsonEquals(value) { fail(path, "value must equal const \(value.debugString)") }
                case "required":
                    checkRequired(instance, value, path: path)
                case "properties":
                    checkProperties(instance, value, path: path)
                case "additionalProperties":
                    checkAdditionalProperties(instance, schema: schema, additional: value, path: path)
                case "items":
                    checkItems(instance, value, path: path)
                case "oneOf":
                    checkOneOf(instance, value, path: path)
                case "allOf":
                    checkAllOf(instance, value, path: path)
                case "if":
                    checkIfThen(instance, schema: schema, ifSchema: value, path: path)
                case "minimum":
                    checkMinimum(instance, value, path: path)
                case "minLength":
                    checkMinLength(instance, value, path: path)
                case "pattern":
                    checkPattern(instance, value, path: path)
                default:
                    errors.append("\(path): \(SchemaError.unsupportedKeyword(keyword))")
                }
            }
        }

        // MARK: keyword checks

        private mutating func checkType(_ instance: JSONValue, typeSchema: JSONValue, path: String) {
            let allowed: [String]
            switch typeSchema {
            case .string(let t): allowed = [t]
            case .array(let ts): allowed = ts.compactMap { if case .string(let t) = $0 { return t } else { return nil } }
            default: fail(path, "type must be a string or array of strings"); return
            }
            if !matchesAnyType(instance, allowed) {
                fail(path, "type mismatch: expected \(allowed.joined(separator: "|")), got \(instance.typeName)")
            }
        }

        private func matchesAnyType(_ instance: JSONValue, _ allowed: [String]) -> Bool {
            allowed.contains { t in
                switch t {
                case "number": return instance.typeName == "number" || instance.typeName == "integer"
                default: return instance.typeName == t
                }
            }
        }

        private mutating func checkEnum(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard case .array(let options) = value else { fail(path, "enum must be an array"); return }
            if !options.contains(where: { $0.jsonEquals(instance) }) {
                fail(path, "value \(instance.debugString) is not one of the enum options")
            }
        }

        private mutating func checkRequired(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard case .object(let obj) = instance else { return } // required only applies to objects
            guard case .array(let names) = value else { fail(path, "required must be an array"); return }
            for case .string(let name) in names where obj[name] == nil {
                fail(path, "missing required property '\(name)'")
            }
        }

        private mutating func checkProperties(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard case .object(let obj) = instance else { return }
            guard case .object(let props) = value else { fail(path, "properties must be an object"); return }
            for (name, subSchema) in props {
                if let child = obj[name] {
                    validate(child, against: subSchema, path: "\(path).\(name)")
                }
            }
        }

        private mutating func checkAdditionalProperties(_ instance: JSONValue, schema: [String: JSONValue], additional: JSONValue, path: String) {
            guard case .object(let obj) = instance else { return }
            var declared = Set<String>()
            if case .object(let props)? = schema["properties"] { declared.formUnion(props.keys) }
            for (name, child) in obj where !declared.contains(name) {
                validate(child, against: additional, path: "\(path).\(name)")
            }
        }

        private mutating func checkItems(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard case .array(let items) = instance else { return }
            for (index, item) in items.enumerated() {
                validate(item, against: value, path: "\(path)[\(index)]")
            }
        }

        private mutating func checkOneOf(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard case .array(let schemas) = value else { fail(path, "oneOf must be an array"); return }
            let matches = schemas.filter { subSchema in
                var probe = Context(root: root)
                probe.validate(instance, against: subSchema, path: path)
                return probe.errors.isEmpty
            }
            if matches.count != 1 {
                fail(path, "value must match exactly one oneOf branch, matched \(matches.count)")
            }
        }

        private mutating func checkAllOf(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard case .array(let schemas) = value else { fail(path, "allOf must be an array"); return }
            for subSchema in schemas {
                validate(instance, against: subSchema, path: path)
            }
        }

        /// `if`/`then` (the reticle schemas never use `else`): when the instance
        /// satisfies `if`, it must also satisfy `then`.
        private mutating func checkIfThen(_ instance: JSONValue, schema: [String: JSONValue], ifSchema: JSONValue, path: String) {
            var probe = Context(root: root)
            probe.validate(instance, against: ifSchema, path: path)
            if probe.errors.isEmpty, let thenSchema = schema["then"] {
                validate(instance, against: thenSchema, path: path)
            }
        }

        private mutating func checkMinimum(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard let bound = value.asDouble else { fail(path, "minimum must be a number"); return }
            switch instance {
            case .integer(let i): if Double(i) < bound { fail(path, "value \(i) < minimum \(bound)") }
            case .double(let d): if d < bound { fail(path, "value \(d) < minimum \(bound)") }
            default: break // minimum only constrains numbers
            }
        }

        private mutating func checkMinLength(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard case .string(let s) = instance else { return }
            guard case .integer(let min) = value else { fail(path, "minLength must be an integer"); return }
            if s.count < Int(min) { fail(path, "string length \(s.count) < minLength \(min)") }
        }

        private mutating func checkPattern(_ instance: JSONValue, _ value: JSONValue, path: String) {
            guard case .string(let s) = instance else { return }
            guard case .string(let pattern) = value else { fail(path, "pattern must be a string"); return }
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                fail(path, "invalid pattern regex \(pattern)"); return
            }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            if regex.firstMatch(in: s, range: range) == nil {
                fail(path, "string '\(s)' does not match pattern \(pattern)")
            }
        }

        /// Resolves a local JSON-pointer `$ref` (`#/$defs/Name`, `#/properties/x`)
        /// against the root schema document.
        private func resolve(_ ref: String) -> JSONValue? {
            guard ref.hasPrefix("#/") else { return nil }
            let tokens = ref.dropFirst(2).split(separator: "/").map {
                $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
            var current = root
            for token in tokens {
                guard case .object(let obj) = current, let next = obj[token] else { return nil }
                current = next
            }
            return current
        }
    }
}

private extension JSONSchemaValidator.JSONValue {
    var asDouble: Double? {
        switch self {
        case .integer(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    var debugString: String {
        switch self {
        case .object: "{object}"
        case .array: "[array]"
        case .string(let s): "\"\(s)\""
        case .integer(let i): "\(i)"
        case .double(let d): "\(d)"
        case .bool(let b): "\(b)"
        case .null: "null"
        }
    }

    /// JSON equality for `enum`/`const`, treating an integer and an equal real
    /// as unequal only when both are numeric of different subtype but same
    /// value — here we compare by value so `const: 1` matches an integer 1.
    func jsonEquals(_ other: JSONSchemaValidator.JSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.integer(a), .integer(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.integer(a), .double(b)), let (.double(b), .integer(a)): return Double(a) == b
        case let (.array(a), .array(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.jsonEquals($1) }
        case let (.object(a), .object(b)):
            return a.count == b.count && a.allSatisfy { k, v in b[k].map { v.jsonEquals($0) } ?? false }
        default: return false
        }
    }
}
