// Jotty/AI/Ollama/DiskSpace.swift
// Disk-space precheck before /api/pull (AI-SPEC §3.5). Uses
// volumeAvailableCapacityForImportantUsageKey — it factors in purgeable
// APFS storage; the plain volumeAvailableCapacityKey undercounts.

import Foundation

enum DiskSpace {

    /// Free bytes on the volume holding `url`, counting purgeable space.
    static func availableSpaceBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Throws OllamaError.insufficientSpace unless the volume holding `url`
    /// has at least `need` × 1.2 bytes free (20% headroom for manifests and
    /// the sha256 verify phase's scratch space).
    static func ensureSpace(at url: URL, forBytes need: Int64) throws {
        let have = try availableSpaceBytes(at: url)
        try ensureSpace(forBytes: need, available: have)
    }

    /// Pure overload — usable from tests with synthetic `available` values.
    static func ensureSpace(forBytes need: Int64, available: Int64) throws {
        guard available > Int64(Double(need) * 1.2) else {
            throw OllamaError.insufficientSpace(needed: need, available: available)
        }
    }
}
