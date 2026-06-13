// Jotty/AI/Ollama/InstalledModel.swift
// One entry from GET /api/tags (AI-SPEC §4.3). Field names mirror the
// Ollama wire format verbatim (snake_case), so no CodingKeys mapping.

import Foundation

struct InstalledModel: Decodable, Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let size: Int64
    let modified_at: String
    let digest: String
    let details: ModelDetails?
}

struct ModelDetails: Decodable, Equatable, Sendable {
    let format: String?
    let family: String?
    let parameter_size: String?
    let quantization_level: String?
}
