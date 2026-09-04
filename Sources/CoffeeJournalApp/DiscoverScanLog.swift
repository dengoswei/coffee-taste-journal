import OSLog

enum DiscoverScanLog {
    static let log = Logger(subsystem: "com.dengos.CoffeeJournal", category: "DiscoverScan")

    static func hashPrefix(_ hash: String) -> String {
        String(hash.prefix(8))
    }

    static func logBegin(
        sourceID: UUID,
        requestRevision: Int,
        liveHash: String,
        approvedHash: String
    ) {
        let match = liveHash == approvedHash
        log.info(
            "begin source=\(sourceID.uuidString, privacy: .public) rev=\(requestRevision) live=\(hashPrefix(liveHash), privacy: .public) approved=\(hashPrefix(approvedHash), privacy: .public) match=\(match)"
        )
        if !match {
            logPromptHashWarning(sourceID: sourceID, liveHash: liveHash, approvedHash: approvedHash)
        }
    }

    static func logPromptHashWarning(sourceID: UUID, liveHash: String, approvedHash: String) {
        log.warning(
            "prompt_hash_mismatch source=\(sourceID.uuidString, privacy: .public) live=\(hashPrefix(liveHash), privacy: .public) approved=\(hashPrefix(approvedHash), privacy: .public) — continuing scan (warning only)"
        )
    }

    static func logExtractStart(sourceID: UUID) {
        log.info("ark start source=\(sourceID.uuidString, privacy: .public)")
    }

    static func logExtractSuccess(sourceID: UUID, status: Int, bytes: Int, durationMs: Int) {
        log.info(
            "ark ok source=\(sourceID.uuidString, privacy: .public) status=\(status) bytes=\(bytes) ms=\(durationMs)"
        )
    }

    static func logExtractFailure(sourceID: UUID, reason: String, status: Int? = nil, durationMs: Int? = nil) {
        if let status, let durationMs {
            log.error(
                "ark fail source=\(sourceID.uuidString, privacy: .public) reason=\(reason, privacy: .public) status=\(status) ms=\(durationMs)"
            )
        } else if let durationMs {
            log.error(
                "ark fail source=\(sourceID.uuidString, privacy: .public) reason=\(reason, privacy: .public) ms=\(durationMs)"
            )
        } else {
            log.error(
                "ark fail source=\(sourceID.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
    }

    static func logCommit(sourceID: UUID, reason: String, candidateCount: Int) {
        log.info(
            "commit source=\(sourceID.uuidString, privacy: .public) reason=\(reason, privacy: .public) candidates=\(candidateCount)"
        )
    }

    static func logStateTransition(sourceID: UUID, from: String, to: String) {
        log.info(
            "state source=\(sourceID.uuidString, privacy: .public) \(from, privacy: .public)->\(to, privacy: .public)"
        )
    }
}
