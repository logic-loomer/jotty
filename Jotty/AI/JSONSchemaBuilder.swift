// Jotty/AI/JSONSchemaBuilder.swift
import Foundation

/// Single source of truth for the `ExtractionResultAI` JSON schema, emitted in
/// the three encodings the cloud providers require. All three flavors describe
/// the same logical shape (mirroring the `@Generable` field names exactly):
///
///     ExtractionResult { tasks: [ExtractedTask] }
///     ExtractedTask {
///       title:         string   // required
///       dueDateISO:    string?  // optional, "yyyy-MM-dd"
///       blockStartISO: string?  // optional, ISO-8601 with TZ
///       blockEndISO:   string?  // optional, ISO-8601 with TZ
///     }
///
/// Only the encoding differs per provider — centralizing here prevents the
/// three copies from drifting (per AI-SPEC §1.3: OpenAI strict mode rejection
/// is easy to trip if the schema is hand-built per provider).
enum JSONSchemaBuilder {

    // MARK: Field descriptions (shared across flavors)

    private static let titleDescription =
        "Verbatim or near-verbatim title from the user's input."
    private static let dueDateDescription =
        "ISO-8601 calendar date 'yyyy-MM-dd' for an explicit deadline only. Omit/null for vague phrasing."
    private static let blockStartDescription =
        "ISO-8601 datetime with timezone offset for the start of a clock-time block. Null unless both start AND end clock times were named."
    private static let blockEndDescription =
        "ISO-8601 datetime with timezone offset for the end of the clock-time block. Required iff blockStartISO is set."
    private static let tasksDescription =
        "All actionable tasks found in the input. Empty array if input is venting, observations, or past-tense prose."

    // MARK: Public flavors

    /// OpenAI Structured Outputs strict mode (`response_format.json_schema.strict: true`).
    /// Per AI-SPEC §1.3: every object level needs `additionalProperties: false`
    /// AND every property listed in `required`. Optional fields cannot be
    /// omitted from `required` — nullability is expressed as `["string", "null"]`.
    /// Returns a `[String: Any]` ready for `JSONSerialization.data(withJSONObject:)`.
    static func openAIStrict() -> [String: Any] {
        let task = taskObjectShape(strict: true)
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "tasks": [
                    "type": "array",
                    "description": tasksDescription,
                    "items": task
                ]
            ],
            "required": ["tasks"]
        ]
    }

    /// Anthropic tool `input_schema`. Per AI-SPEC §1.2.
    /// Plain (loose) JSON Schema: only `tasks` required at the top, only
    /// `title` required on a task, optional fields typed as `"string"`,
    /// no `additionalProperties` constraint needed.
    static func anthropicToolInput() -> [String: Any] {
        let task = taskObjectShape(strict: false)
        return [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "description": tasksDescription,
                    "items": task
                ]
            ],
            "required": ["tasks"]
        ]
    }

    /// Gemini `responseSchema`. Per AI-SPEC §1.4.
    /// Gemini's Schema type is OpenAPI-3.0 flavored: uppercase type enums
    /// (`STRING`, `OBJECT`, `ARRAY`, `BOOLEAN`, `INTEGER`, `NUMBER`) and
    /// `nullable: true` for optional fields — array-form types like
    /// `["STRING", "NULL"]` are not accepted. No `additionalProperties`.
    static func geminiResponseSchema() -> [String: Any] {
        let loose: [String: Any] = anthropicToolInput()
        return geminify(loose, optionalFields: ["dueDateISO", "blockStartISO", "blockEndISO"])
    }

    // MARK: Private

    /// The per-task schema in either strict (OpenAI) or loose (Anthropic) form.
    private static func taskObjectShape(strict: Bool) -> [String: Any] {
        let optionalType: Any = strict ? ["string", "null"] : "string"

        var shape: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": titleDescription],
                "dueDateISO": ["type": optionalType, "description": dueDateDescription],
                "blockStartISO": ["type": optionalType, "description": blockStartDescription],
                "blockEndISO": ["type": optionalType, "description": blockEndDescription]
            ]
        ]

        if strict {
            shape["additionalProperties"] = false
            shape["required"] = ["title", "dueDateISO", "blockStartISO", "blockEndISO"]
        } else {
            shape["required"] = ["title"]
        }
        return shape
    }

    /// Recursively rewrites a loose JSON-Schema dictionary into Gemini's
    /// Schema dialect: uppercase the `type` strings, mark the named optional
    /// properties `nullable: true`, and drop keys Gemini does not understand.
    private static func geminify(_ schema: [String: Any], optionalFields: Set<String>) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in schema {
            switch key {
            case "additionalProperties":
                continue // not part of the Gemini Schema type
            case "type":
                if let type = value as? String {
                    out["type"] = type.uppercased()
                } else {
                    out["type"] = value
                }
            case "properties":
                guard let properties = value as? [String: Any] else {
                    out[key] = value
                    continue
                }
                var rewritten: [String: Any] = [:]
                for (name, propValue) in properties {
                    guard var prop = propValue as? [String: Any] else {
                        rewritten[name] = propValue
                        continue
                    }
                    prop = geminify(prop, optionalFields: optionalFields)
                    if optionalFields.contains(name) {
                        prop["nullable"] = true
                    }
                    rewritten[name] = prop
                }
                out["properties"] = rewritten
            case "items":
                if let items = value as? [String: Any] {
                    out["items"] = geminify(items, optionalFields: optionalFields)
                } else {
                    out[key] = value
                }
            default:
                out[key] = value
            }
        }
        return out
    }
}
