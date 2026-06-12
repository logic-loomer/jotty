// JottyTests/AI/JSONSchemaBuilderTests.swift
// Schema-shape assertions for the three JSONSchemaBuilder flavors:
// OpenAI strict (additionalProperties:false everywhere, every property in
// required, optionals as ["string","null"]), Anthropic tool input_schema
// (loose JSON Schema), and Gemini Schema (uppercase types + nullable:true).
// Also asserts field-name parity across all flavors against the
// ExtractedTaskAI @Generable shape, plus JSONSerialization round-trips.

import XCTest
@testable import Jotty

final class JSONSchemaBuilderTests: XCTestCase {

    private static let expectedTaskFields: Set<String> = [
        "title", "dueDateISO", "blockStartISO", "blockEndISO"
    ]

    // MARK: - Helpers

    /// Recursively visits every dictionary in a JSON-ish structure.
    private func walkObjects(_ value: Any, _ visit: ([String: Any]) -> Void) {
        if let dict = value as? [String: Any] {
            visit(dict)
            for (_, v) in dict { walkObjects(v, visit) }
        } else if let array = value as? [Any] {
            for v in array { walkObjects(v, visit) }
        }
    }

    private func taskItemsSchema(in schema: [String: Any]) throws -> [String: Any] {
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any], "missing top-level properties")
        let tasks = try XCTUnwrap(properties["tasks"] as? [String: Any], "missing tasks property")
        return try XCTUnwrap(tasks["items"] as? [String: Any], "missing tasks.items")
    }

    // MARK: - OpenAI strict flavor

    func testOpenAIStrictTopLevelShape() throws {
        let schema = JSONSchemaBuilder.openAIStrict()
        XCTAssertEqual(schema["type"] as? String, "object")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let tasks = try XCTUnwrap(properties["tasks"] as? [String: Any])
        XCTAssertEqual(tasks["type"] as? String, "array")
    }

    func testOpenAIStrictAllObjectsHaveAdditionalPropertiesFalse() {
        let schema = JSONSchemaBuilder.openAIStrict()
        var objectLevels = 0
        walkObjects(schema) { dict in
            guard dict["type"] as? String == "object" else { return }
            objectLevels += 1
            XCTAssertEqual(
                dict["additionalProperties"] as? Bool, false,
                "object level missing additionalProperties: false — OpenAI strict mode rejects this: \(dict)"
            )
        }
        XCTAssertGreaterThanOrEqual(objectLevels, 2, "expected at least top-level + task object levels")
    }

    func testOpenAIStrictRequiredListsEveryProperty() {
        let schema = JSONSchemaBuilder.openAIStrict()
        walkObjects(schema) { dict in
            guard dict["type"] as? String == "object",
                  let properties = dict["properties"] as? [String: Any] else { return }
            let required = Set((dict["required"] as? [String]) ?? [])
            XCTAssertEqual(
                required, Set(properties.keys),
                "OpenAI strict mode requires every property listed in required: \(dict)"
            )
        }
    }

    func testOpenAIStrictOptionalFieldsTypedStringOrNull() throws {
        let schema = JSONSchemaBuilder.openAIStrict()
        let item = try taskItemsSchema(in: schema)
        let properties = try XCTUnwrap(item["properties"] as? [String: Any])

        // Required field stays a plain string.
        let title = try XCTUnwrap(properties["title"] as? [String: Any])
        XCTAssertEqual(title["type"] as? String, "string")

        // Optionals must be ["string", "null"] — strict mode cannot omit them
        // from required, so nullability is expressed in the type union.
        for field in ["dueDateISO", "blockStartISO", "blockEndISO"] {
            let prop = try XCTUnwrap(properties[field] as? [String: Any], "missing \(field)")
            let type = try XCTUnwrap(prop["type"] as? [String], "\(field) type should be a [String] union")
            XCTAssertEqual(Set(type), Set(["string", "null"]), "\(field) should be [\"string\", \"null\"]")
        }
    }

    // MARK: - Anthropic tool input_schema flavor

    func testAnthropicTopLevelShapeAndLooseRequired() throws {
        let schema = JSONSchemaBuilder.anthropicToolInput()
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["tasks"])

        let item = try taskItemsSchema(in: schema)
        XCTAssertEqual(item["type"] as? String, "object")
        XCTAssertEqual(item["required"] as? [String], ["title"],
                       "only title is required on a task in the loose Anthropic flavor")
    }

    func testAnthropicOptionalFieldsArePlainStrings() throws {
        let schema = JSONSchemaBuilder.anthropicToolInput()
        let item = try taskItemsSchema(in: schema)
        let properties = try XCTUnwrap(item["properties"] as? [String: Any])
        for field in ["title", "dueDateISO", "blockStartISO", "blockEndISO"] {
            let prop = try XCTUnwrap(properties[field] as? [String: Any], "missing \(field)")
            XCTAssertEqual(prop["type"] as? String, "string", "\(field) should be a plain string type")
        }
    }

    // MARK: - Gemini Schema flavor

    func testGeminiUppercaseTypes() throws {
        let schema = JSONSchemaBuilder.geminiResponseSchema()
        XCTAssertEqual(schema["type"] as? String, "OBJECT")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let tasks = try XCTUnwrap(properties["tasks"] as? [String: Any])
        XCTAssertEqual(tasks["type"] as? String, "ARRAY")
        let item = try XCTUnwrap(tasks["items"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "OBJECT")
    }

    func testGeminiAllTypeStringsAreUppercase() {
        let schema = JSONSchemaBuilder.geminiResponseSchema()
        let allowed: Set<String> = ["STRING", "OBJECT", "ARRAY", "BOOLEAN", "INTEGER", "NUMBER"]
        walkObjects(schema) { dict in
            guard let type = dict["type"] else { return }
            if let typeString = type as? String {
                XCTAssertTrue(allowed.contains(typeString),
                              "Gemini type must be an uppercase enum, got \(typeString)")
            } else {
                XCTFail("Gemini types must be single strings (no array-form types), got \(type)")
            }
        }
    }

    func testGeminiOptionalFieldsUseNullable() throws {
        let schema = JSONSchemaBuilder.geminiResponseSchema()
        let item = try taskItemsSchema(in: schema)
        let properties = try XCTUnwrap(item["properties"] as? [String: Any])

        let title = try XCTUnwrap(properties["title"] as? [String: Any])
        XCTAssertEqual(title["type"] as? String, "STRING")
        XCTAssertNil(title["nullable"], "title is required — no nullable flag")

        for field in ["dueDateISO", "blockStartISO", "blockEndISO"] {
            let prop = try XCTUnwrap(properties[field] as? [String: Any], "missing \(field)")
            XCTAssertEqual(prop["type"] as? String, "STRING")
            XCTAssertEqual(prop["nullable"] as? Bool, true, "\(field) should be nullable: true")
        }
    }

    func testGeminiHasNoAdditionalPropertiesKeys() {
        // additionalProperties is a JSON-Schema concept; Gemini's OpenAPI-3.0
        // flavored Schema type does not use it.
        let schema = JSONSchemaBuilder.geminiResponseSchema()
        walkObjects(schema) { dict in
            XCTAssertNil(dict["additionalProperties"],
                         "Gemini Schema should not carry additionalProperties")
        }
    }

    // MARK: - Cross-flavor invariants

    func testFieldNameParityAcrossAllFlavors() throws {
        let flavors: [(String, [String: Any])] = [
            ("openai", JSONSchemaBuilder.openAIStrict()),
            ("anthropic", JSONSchemaBuilder.anthropicToolInput()),
            ("gemini", JSONSchemaBuilder.geminiResponseSchema())
        ]
        for (name, schema) in flavors {
            let topProperties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(topProperties.keys), ["tasks"], "\(name): top-level properties drift")

            let item = try taskItemsSchema(in: schema)
            let taskProperties = try XCTUnwrap(item["properties"] as? [String: Any])
            XCTAssertEqual(Set(taskProperties.keys), Self.expectedTaskFields,
                           "\(name): task field names drifted from ExtractedTaskAI shape")
        }
    }

    func testAllFlavorsRoundTripThroughJSONSerialization() throws {
        let flavors: [(String, [String: Any])] = [
            ("openai", JSONSchemaBuilder.openAIStrict()),
            ("anthropic", JSONSchemaBuilder.anthropicToolInput()),
            ("gemini", JSONSchemaBuilder.geminiResponseSchema())
        ]
        for (name, schema) in flavors {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(schema),
                          "\(name): schema contains non-JSON values")
            let data = try JSONSerialization.data(withJSONObject: schema)
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(decoded, "\(name): round-trip decode failed")
        }
    }

    func testFlavorsAreDistinct() throws {
        let openAI = try JSONSerialization.data(withJSONObject: JSONSchemaBuilder.openAIStrict(), options: .sortedKeys)
        let anthropic = try JSONSerialization.data(withJSONObject: JSONSchemaBuilder.anthropicToolInput(), options: .sortedKeys)
        let gemini = try JSONSerialization.data(withJSONObject: JSONSchemaBuilder.geminiResponseSchema(), options: .sortedKeys)
        XCTAssertNotEqual(openAI, anthropic)
        XCTAssertNotEqual(anthropic, gemini)
        XCTAssertNotEqual(openAI, gemini)
    }
}
