// Jotty/AI/Ollama/Quarantine.swift
// Strips the com.apple.quarantine xattr from the extracted Ollama.app so
// macOS doesn't block `Process.run()` on the downloaded binary (AI-SPEC §3,
// failure mode 5). Codesign verification ALWAYS runs after stripping —
// quarantine removal never bypasses the signature check.

import Foundation

enum Quarantine {
    /// Recursively removes the quarantine flag from `url`. A non-zero exit
    /// status is fine — the flag may simply not be set — so this only throws
    /// when the `xattr` process itself cannot run.
    static func strip(at url: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-dr", "com.apple.quarantine", url.path]
        // Silence "No such xattr" noise on stderr.
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        // Non-zero is fine — flag may not be set. Do NOT throw.
    }
}
