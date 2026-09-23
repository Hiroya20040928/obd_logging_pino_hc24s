import Foundation

final class DiagnosticLogWriter {
    private(set) var csvURL: URL?
    private(set) var textURL: URL?
    private var csvHandle: FileHandle?
    private var textHandle: FileHandle?

    var isOpen: Bool { csvHandle != nil && textHandle != nil }

    static var logsDirectory: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let dir = docs.appendingPathComponent(
            "Pino OBD Logs",
            isDirectory: true
        )

        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        return dir
    }

    static var probePlanURL: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        return docs.appendingPathComponent("PinoProbePlan.txt")
    }

    func ensureProbePlanExists() {
        let url = Self.probePlanURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let template = """
        # Pino Auto Logger v4
        # v4ではSZ Viewer由来のSUZUKI1/KWP初期化と21 00をアプリ内で固定実装します．
        # このファイルは将来のread-only追加調査用に残しています．
        """

        try? template.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    func loadCustomProbePlan() -> [ProbeDefinition] {
        []
    }

    func start() throws -> (URL, URL) {
        close()
        ensureProbePlanExists()

        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let stem = "HC24S_SUZUKI1_\(f.string(from: now))"

        let csv = Self.logsDirectory.appendingPathComponent(stem + ".csv")
        let txt = Self.logsDirectory.appendingPathComponent(stem + ".txt")

        FileManager.default.createFile(atPath: csv.path, contents: nil)
        FileManager.default.createFile(atPath: txt.path, contents: nil)

        csvHandle = try FileHandle(forWritingTo: csv)
        textHandle = try FileHandle(forWritingTo: txt)
        csvURL = csv
        textURL = txt

        try writeCSV([
            "timestamp_iso8601",
            "unix_ms",
            "record_type",
            "direction",
            "label",
            "command",
            "classification",
            "request_sid",
            "response_sid",
            "nrc",
            "kwp_frames",
            "raw"
        ])

        try writeText("Pino Auto Logger v4 HC24S SUZUKI1 session\n")
        try writeText("Started: \(iso(now))\n")
        try writeText(
            "Authority: raw ELM/KWP response. SZ_GENERIC_MAP rows are decoded candidates until HC24S correlation confirms offsets.\n\n"
        )

        return (csv, txt)
    }

    func appendTransport(_ r: TransportRecord) {
        guard isOpen else { return }

        try? writeCSV([
            iso(r.date),
            unixMS(r.date),
            "transport",
            r.direction,
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            r.text
        ])

        try? writeText(
            "[\(iso(r.date))] \(r.direction) \(printable(r.text))\n"
        )
    }

    func appendProbe(_ r: ProbeResult) {
        guard isOpen else { return }

        let c = r.classification
        let frames = c.frames.map(\.hex).joined(separator: " | ")

        try? writeCSV([
            iso(r.date),
            unixMS(r.date),
            "probe",
            "",
            r.definition.label,
            r.definition.command,
            c.summary,
            hex(c.requestSID),
            hex(c.responseSID),
            hex(c.nrc),
            frames,
            r.raw
        ])

        try? writeText(
            "[\(iso(r.date))] PROBE \(r.definition.label) TX=\(r.definition.command) RESULT=\(c.summary)\n"
        )
        try? writeText("  RAW: \(printable(r.raw))\n")

        for f in c.frames {
            try? writeText(
                "  KWP: \(f.hex) payload=\(f.payloadHex)\n"
            )
        }
    }

    func appendLiveSnapshot(_ s: SuzukiGenericLiveSnapshot) {
        guard isOpen else { return }

        let json: [String: Any] = [
            "map": "SZ_GENERIC_MAP_UNVERIFIED_FOR_HC24S",
            "sanity_score_6": s.sanityScore,
            "data_length": s.dataLength,
            "rpm": s.rpm,
            "coolant_c": s.coolantC,
            "speed_kmh": s.speedKmh,
            "throttle_pct": s.throttlePct,
            "intake_c": s.intakeC,
            "baro_kpa": s.baroKpa,
            "battery_v": s.batteryV,
            "engine_load_pct": s.engineLoadPct,
            "ignition_advance_deg": s.ignitionAdvanceDeg,
            "map_kpa": s.mapKpa,
            "maf_gps": s.mafGps,
            "o2_b1s1_v": s.o2B1S1V,
            "stft1_pct": s.stft1Pct,
            "ltft1_pct": s.ltft1Pct,
            "fuel_pulse1_ms": s.fuelPulse1Ms,
            "fuel_pulse2_ms": s.fuelPulse2Ms,
            "desired_idle_rpm": s.desiredIdleRPM,
            "iac_pct": s.iacPct
        ]

        let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys]
        )
        let string = data.flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"

        try? writeCSV([
            iso(s.timestamp),
            unixMS(s.timestamp),
            "decoded_candidate",
            "",
            "SZ_GENERIC_MAP",
            "2100",
            "UNVERIFIED_HC24S_MAP",
            "21",
            "61",
            "",
            "",
            string
        ])

        try? writeText(
            "[\(iso(s.timestamp))] SZ_GENERIC_MAP score=\(s.sanityScore)/6 \(string)\n"
        )
    }

    func appendEvent(_ event: String, note: String = "") {
        guard isOpen else { return }

        let now = Date()

        try? writeCSV([
            iso(now),
            unixMS(now),
            "event",
            "",
            event,
            "",
            "",
            "",
            "",
            "",
            "",
            note
        ])

        try? writeText(
            "[\(iso(now))] EVENT \(event) \(note)\n"
        )
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
        f.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return f.string(from: d)
    }

    private func unixMS(_ d: Date) -> String {
        String(Int64(d.timeIntervalSince1970 * 1000))
    }

    private func hex(_ x: UInt8?) -> String {
        x.map { String(format: "%02X", $0) } ?? ""
    }

    private func printable(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",")
            || s.contains("\"")
            || s.contains("\n")
            || s.contains("\r") {
            return "\""
                + s.replacingOccurrences(of: "\"", with: "\"\"")
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\n", with: "\\n")
                + "\""
        }

        return s
    }
}
