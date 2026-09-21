import Foundation

final class DiagnosticLogWriter {
    private(set) var csvURL: URL?
    private(set) var textURL: URL?
    private var csvHandle: FileHandle?
    private var textHandle: FileHandle?

    var isOpen: Bool { csvHandle != nil && textHandle != nil }

    static var logsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Pino OBD Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var probePlanURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("PinoProbePlan.txt")
    }

    func ensureProbePlanExists() {
        let url = Self.probePlanURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let template = """
        # Pino Auto Logger v3 custom probe plan
        # 1行1コマンド．先頭を R: にすると，positive responseが確認された場合だけ走行中に反復取得します．
        # 先頭を 1: にすると1回だけ送信します．
        # 安全のため，アプリはread-only allowlist以外のSIDを自動拒否します．
        # 例:
        # R:2100
        # 1:1A90
        """
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }

    func loadCustomProbePlan() -> [ProbeDefinition] {
        ensureProbePlanExists()
        guard let text = try? String(contentsOf: Self.probePlanURL, encoding: .utf8) else { return [] }
        var result: [ProbeDefinition] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            var repeatIfPositive = false
            if line.uppercased().hasPrefix("R:") {
                repeatIfPositive = true
                line = String(line.dropFirst(2))
            } else if line.uppercased().hasPrefix("1:") {
                line = String(line.dropFirst(2))
            }

            let command = line.replacingOccurrences(of: " ", with: "").uppercased()
            guard KWPProtocol.isSafeReadOnly(command) else { continue }
            result.append(ProbeDefinition(command: command, label: "CUSTOM", repeatIfPositive: repeatIfPositive))
        }
        return result
    }

    func start() throws -> (URL, URL) {
        close()
        ensureProbePlanExists()

        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "HC24S_DISCOVERY_\(f.string(from: now))"

        let csv = Self.logsDirectory.appendingPathComponent(stem + ".csv")
        let txt = Self.logsDirectory.appendingPathComponent(stem + ".txt")

        FileManager.default.createFile(atPath: csv.path, contents: nil)
        FileManager.default.createFile(atPath: txt.path, contents: nil)

        csvHandle = try FileHandle(forWritingTo: csv)
        textHandle = try FileHandle(forWritingTo: txt)
        csvURL = csv
        textURL = txt

        try writeCSV([
            "timestamp_iso8601", "unix_ms", "record_type", "direction", "label", "command",
            "classification", "request_sid", "response_sid", "nrc", "kwp_frames", "raw"
        ])

        try writeText("Pino Auto Logger v3 HC24S safe discovery session\n")
        try writeText("Started: \(iso(now))\n")
        try writeText("Purpose: raw, checksummed KWP capture; no guessed live-data decoding.\n\n")
        return (csv, txt)
    }

    func appendTransport(_ r: TransportRecord) {
        guard isOpen else { return }
        try? writeCSV([
            iso(r.date), unixMS(r.date), "transport", r.direction, "", "", "", "", "", "", "", r.text
        ])
        try? writeText("[\(iso(r.date))] \(r.direction) \(printable(r.text))\n")
    }

    func appendProbe(_ r: ProbeResult) {
        guard isOpen else { return }
        let c = r.classification
        let frames = c.frames.map(\.hex).joined(separator: " | ")
        try? writeCSV([
            iso(r.date), unixMS(r.date), "probe", "", r.definition.label, r.definition.command,
            c.summary,
            hex(c.requestSID), hex(c.responseSID), hex(c.nrc),
            frames, r.raw
        ])
        try? writeText("[\(iso(r.date))] PROBE \(r.definition.label) TX=\(r.definition.command) RESULT=\(c.summary)\n")
        try? writeText("  RAW: \(printable(r.raw))\n")
        for f in c.frames {
            try? writeText("  KWP: \(f.hex) payload=\(f.payloadHex)\n")
        }
    }

    func appendEvent(_ event: String, note: String = "") {
        guard isOpen else { return }
        let now = Date()
        try? writeCSV([iso(now), unixMS(now), "event", "", event, "", "", "", "", "", "", note])
        try? writeText("[\(iso(now))] EVENT \(event) \(note)\n")
    }

    func close() {
        try? csvHandle?.synchronize()
        try? textHandle?.synchronize()
        try? csvHandle?.close()
        try? textHandle?.close()
        csvHandle = nil
        textHandle = nil
    }

    deinit {
        close()
    }

    private func writeCSV(_ values: [String]) throws {
        guard let csvHandle else { return }
        let line = values.map(csvEscape).joined(separator: ",") + "\n"
        try csvHandle.write(contentsOf: Data(line.utf8))
        try csvHandle.synchronize()
    }

    private func writeText(_ s: String) throws {
        guard let textHandle else { return }
        try textHandle.write(contentsOf: Data(s.utf8))
        try textHandle.synchronize()
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private func unixMS(_ d: Date) -> String {
        String(Int64(d.timeIntervalSince1970 * 1000))
    }

    private func hex(_ x: UInt8?) -> String {
        x.map { String(format: "%02X", $0) } ?? ""
    }

    private func printable(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        return s
    }
}
