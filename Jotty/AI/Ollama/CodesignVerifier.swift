// Jotty/AI/Ollama/CodesignVerifier.swift
// Verifies the code signature of the extracted Ollama.app before any launch
// (AI-SPEC §3.1). Verification failure is fatal: the installer deletes the
// bundle and never proceeds to launch (failure mode 4 — "Never proceed").
//
// Team ID pinning: the expected Ollama Inc. Developer ID Team ID constant
// lives in OllamaInstaller (expectedOllamaTeamID) and is passed in here.

import Foundation

enum CodesignVerifier {
    /// Runs `/usr/bin/codesign --verify --deep --strict` against the bundle,
    /// then (if `requiredTeamID` is non-nil) pins the signing Team ID by
    /// inspecting `codesign -dvv` output for `TeamIdentifier=<id>`.
    /// Throws `OllamaError.signatureInvalid` on any mismatch.
    static func verify(bundle: URL, requiredTeamID: String?) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--deep", "--strict", bundle.path]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw OllamaError.signatureInvalid
        }

        // Optional Team ID pin — codesign -dvv prints details to stderr.
        if let required = requiredTeamID {
            let inspect = Process()
            inspect.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            inspect.arguments = ["-dvv", bundle.path]
            let outPipe = Pipe()
            inspect.standardError = outPipe
            inspect.standardOutput = FileHandle.nullDevice
            try inspect.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            inspect.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard output.contains("TeamIdentifier=\(required)") else {
                throw OllamaError.signatureInvalid
            }
        }
    }
}
