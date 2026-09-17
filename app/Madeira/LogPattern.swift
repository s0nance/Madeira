import Foundation

/// Canonicalize a log line into a "signature" — strip variable parts
/// (hex addresses, thread IDs, counts, RIP values) so that semantically
/// identical events bucket together for dedup.
///
/// Example transformations:
///   `0024:trace:file:NtWriteFile = SUCCESS (52)`  → `T:trace:file:NtWriteFile = SUCCESS (#)`
///   `[iOS] CompileBlock: RIP=0x140028d46 MaxInst=0`  → `[iOS] CompileBlock: RIP=0x? MaxInst=#`
///   `[mach_exc] UNHANDLED #1234 pc=0x123abc addr=0x10 ...`  → `[mach_exc] UNHANDLED #_ pc=0x? addr=0x? ...`
///   `[CALLRET_OOB #5] UNDERFLOW callret_sp=0x...` → `[CALLRET_OOB #_] UNDERFLOW callret_sp=0x?`
struct LogPattern {
    /// Returns (signature, displayLevel) for a raw log line.
    static func canonicalize(_ raw: String) -> (signature: String, level: LogStore.LogEntry.Level) {
        var s = raw

        /* Periodic gauges collapse to their TAG ALONE.
         *
         * These probes tick several times a second and every tick carries a
         * different reading -- cycle=274, age=76s, parked=5, pos=9305. The
         * generic rules below only blank integers of three digits or more (the
         * threshold exists to preserve meaningful small values like
         * MaxInst=0), so one- and two-digit counters kept each tick distinct.
         * Every tick therefore became a NEW entry, jumped to the top of a list
         * sorted by last-seen, and pushed everything else down -- hundreds of
         * times a minute. The console was unreadable while a program ran.
         *
         * A gauge wants one row showing its latest reading, which is exactly
         * what the existing ×N collapsing gives once the signature stops
         * varying. Matched on the bracketed tag rather than by listing every
         * counter name, because the counters change whenever a probe is
         * revised and the tag does not. */
        for tag in Self.periodicTags where s.hasPrefix(tag) {
            return (tag, inferLevel(from: s))
        }

        // Strip leading `[HH:MM:SS.mmm]` timestamp prefix from wine_log_write
        if let r = s.range(of: #"^\[\d{2}:\d{2}:\d{2}\.\d{3}\]\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }

        // Detect level marker right after timestamp, like `[INFO]` `[ERR]` etc.
        var level = inferLevel(from: s)

        // Strip top-level `[LEVEL]` if present
        if let r = s.range(of: #"^\[(INFO|OK|ERR|DBG|WARN|FATAL)\]\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }

        // Strip the `I 24 ` / `E 24 ` / `D 24 ` Wine fixme/err/trace prefix
        // (level letter + thread hex id from wine_log_write/dprintf)
        if let r = s.range(of: #"^[IEDW]\s+[0-9a-fA-F]+\s+"#, options: .regularExpression) {
            s.removeSubrange(r)
        }

        // Strip wine thread-id prefix `0024:` (4 hex digits + colon)
        s = s.replacingOccurrences(
            of: #"^[0-9a-fA-F]{4}:"#,
            with: "T:",
            options: .regularExpression
        )

        // Replace hex literals with placeholder
        s = s.replacingOccurrences(
            of: #"0x[0-9a-fA-F]+"#,
            with: "0x?",
            options: .regularExpression
        )

        // Replace #NNNN count suffixes (e.g. "UNHANDLED #1234", "CALLRET_OOB #5")
        s = s.replacingOccurrences(
            of: #"#\d+"#,
            with: "#_",
            options: .regularExpression
        )

        // Replace decimal integers > 2 digits with `#` (preserves small values
        // like "MaxInst=0" but collapses size/byte/count fields)
        s = s.replacingOccurrences(
            of: #"\b\d{3,}\b"#,
            with: "#",
            options: .regularExpression
        )

        // Collapse repeated whitespace
        s = s.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Cap signature length for display
        if s.count > 200 {
            s = String(s.prefix(200))
        }

        return (s, level)
    }

    /// Probes that report a running measurement on a timer. Their value is
    /// the LATEST reading, never the history, so they collapse to one row.
    private static let periodicTags = [
        "[footprint]", "[waiters]", "[alert-ring]", "[pool-rot]", "[phys-map]",
        "[mem-census]", "[dyn-census]", "[buf-site]", "[live]", "[trim]",
        "[thread-stacks]", "[commit-zero]",
    ]

    /// Infer log level from raw line content.
    private static func inferLevel(from line: String) -> LogStore.LogEntry.Level {
        let l = line.lowercased()
        if l.contains("fatal") || l.contains("c000001d") || l.contains("c0000005") ||
            l.contains("ntterminateprocess") || l.contains("unhandled") ||
            l.contains("seh:") || l.contains("err:") || line.hasPrefix("E ") {
            return .error
        }
        if l.contains("ok ") || l.contains(" ok)") || l.contains("succeeded") ||
            l.contains("success") || l.contains("present #") || line.contains("🎉") {
            return .success
        }
        if l.contains("warn") || line.hasPrefix("W ") {
            return .info  // shown distinctly via level color anyway
        }
        if line.hasPrefix("D ") || l.contains("debug") || l.contains("trace:") {
            return .debug
        }
        return .info
    }
}
