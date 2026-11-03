//
//  SchemaValidator.swift
//  WrappBuilder
//
//  Checks JSON against a JSON Schema with ajv, run in JavaScriptCore.

import Foundation
import JavaScriptCore

/// Checks documents against JSON Schemas (draft 2020-12) with ajv, run in
/// JavaScriptCore (`JavaScript/README.md` has why ajv).
///
/// Not thread-safe, as its `JSContext` isn't: make one where it's used.
/// Making one compiles nothing; each schema is compiled the first time a
/// document is checked against it.
nonisolated final class SchemaValidator {
    /// What's wrong with a document, in words for a bundle's author.
    struct Problem: Hashable, CustomStringConvertible {
        /// Where, as a JSON pointer (`/editions/0/source`); empty for the
        /// whole document.
        let path: String
        let message: String

        var description: String { "\(path.isEmpty ? "/" : path): \(message)" }
    }

    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    private let context: JSContext
    private let validator: JSValue
    private var exception: String?

    init() throws {
        guard let context = JSContext() else { throw Error(description: "JavaScriptCore made no context") }
        self.context = context
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(ajvScript, withSourceURL: URL(string: "ajv.min.js"))
        if let exception { throw Error(description: "ajv didn't load: \(exception)") }
        guard let validator = context.objectForKeyedSubscript("Validator"), validator.isObject else {
            throw Error(description: "ajv's script defines no Validator")
        }
        self.validator = validator
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() }
    }

    /// Adds a schema, which others name by its `$id`.
    func addSchema(_ json: Data) throws {
        try call("addSchema", [String(decoding: json, as: UTF8.self)])
    }

    /// The problems with `document` (JSON-shaped values) against the schema
    /// with the `$id` `schemaID`; none when it's valid.
    func problems(with document: Any, against schemaID: String) throws -> [Problem] {
        let json = try JSONSerialization.data(withJSONObject: document, options: [.fragmentsAllowed])
        let result = try call("validate", [schemaID, String(decoding: json, as: UTF8.self)])
        guard let text = result.toString() else { throw Error(description: "ajv returned nothing") }
        let outcome = try JSONDecoder().decode(Outcome.self, from: Data(text.utf8))
        return outcome.valid ? [] : Self.problems(from: outcome.errors)
    }

    @discardableResult
    private func call(_ method: String, _ arguments: [Any]) throws -> JSValue {
        exception = nil
        let result = validator.invokeMethod(method, withArguments: arguments)
        if let exception { throw Error(description: exception) }
        guard let result else { throw Error(description: "\(method) returned nothing") }
        return result
    }

    // MARK: - ajv's errors, reworded

    private struct Outcome: Decodable {
        let valid: Bool
        let errors: [AjvError]
    }

    private struct AjvError: Decodable {
        let instancePath: String
        let keyword: String
        let message: String?
        let params: [String: Parameter]
    }

    /// A value in an error's `params`: only text, numbers and lists of text
    /// are read.
    private enum Parameter: Decodable {
        case text(String)
        case number(Double)
        case texts([String])
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if let texts = try? container.decode([String].self) {
                self = .texts(texts)
            } else {
                self = .other
            }
        }

        var text: String? {
            switch self {
            case .text(let text): text
            case .number(let number):
                if number == number.rounded() { String(Int(number)) } else { String(number) }
            case .texts(let texts): texts.joined(separator: ", ")
            case .other: nil
            }
        }
    }

    /// ajv's errors, reworded, without those a `oneOf`, `anyOf` or `if`
    /// adds only to say a branch failed: the branch's own errors say why.
    private static func problems(from errors: [AjvError]) -> [Problem] {
        var seen = Set<Problem>()
        return errors.compactMap { error in
            let message: String
            switch error.keyword {
            case "additionalProperties", "unevaluatedProperties":
                let key = error.params["additionalProperty"]?.text ?? error.params["unevaluatedProperty"]?.text
                message = "\(key ?? "a key") isn't something this can have; is it mistyped?"
            case "required":
                message = "needs \(error.params["missingProperty"]?.text ?? "a key it's missing")"
            case "enum":
                message = "must be one of: \(error.params["allowedValues"]?.text ?? "the values listed in the schema")"
            case "const":
                message = "must be \(error.params["allowedValue"]?.text ?? "the value the schema gives")"
            case "type":
                message = "must be \(article(error.params["type"]?.text ?? "another type"))"
            case "pattern":
                message = "isn't written as it should be (\(error.params["pattern"]?.text ?? "see the schema"))"
            case "oneOf", "anyOf", "if", "not":
                return nil
            default:
                message = error.message ?? "isn't valid (\(error.keyword))"
            }
            let problem = Problem(path: error.instancePath, message: message)
            return seen.insert(problem).inserted ? problem : nil
        }
    }

    private static func article(_ type: String) -> String {
        switch type {
        case "string": "text, in quotes"
        case "integer": "a whole number"
        case "number": "a number"
        case "boolean": "true or false"
        case "array": "a list"
        case "object": "a set of keys and values"
        default: type
        }
    }
}
