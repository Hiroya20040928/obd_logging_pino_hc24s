import Foundation

final class TripLogWriter {
    private(set) var fileURL: URL?
    private var handle: FileHandle?
    private var metrics = TripMetrics()
    private var startedAt: Date?
    private let byteColumns = Array(0..<65).map { String(format: "b%02d", $0) }

    static var logsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Pino OBD Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start(profile: String) throws -> URL {
        close()
        let now = Date()
        startedAt = now
        metrics = TripMetrics()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.logsDirectory.appendingPathComponent("HC24S_\(f.string(from: now)).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        handle = h
        fileURL = url
        var header = [
            "timestamp_iso8601", "unix_ms", "profile", "rpm", "speed_kmh", "coolant_c", "iat_c",
            "throttle_pct", "tps_v", "engine_load_pct", "map_kpa", "maf_gps", "ignition_advance_deg",
            "o2_b1s1_v", "stft1_pct", "ltft1_pct", "stft2_pct", "ltft2_pct", "fuel_pulse1_ms",
            "fuel_pulse2_ms", "baro_kpa", "iac_pos_pct", "desired_idle_rpm", "battery_v",
            "fuel_rate_lph_est", "instant_km_per_l_est", "trip_distance_km", "trip_fuel_l_est",
            "trip_avg_km_per_l_est", "raw_payload_hex", "raw_response"
        ]
        header.append(contentsOf: byteColumns)
        try writeLine(header.map(csvEscape).joined(separator: ","))
        return url
    }

    func append(frame: EngineFrame, profile: String, at now: Date = Date()) throws {
        guard handle != nil else { return }
        let m = metrics.update(at: now, frame: frame)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var row: [String] = [
            iso.string(from: now),
            String(Int64(now.timeIntervalSince1970 * 1000)),
            profile,
            num(frame.rpm), num(frame.speedKmh), num(frame.coolantC), num(frame.iatC),
            num(frame.throttlePct), num(frame.tpsV), num(frame.engineLoadPct), num(frame.mapKPa),
            num(frame.mafGps), num(frame.ignitionAdvanceDeg), num(frame.o2B1S1V), num(frame.stft1Pct),
            num(frame.ltft1Pct), num(frame.stft2Pct), num(frame.ltft2Pct), num(frame.fuelPulse1Ms),
            num(frame.fuelPulse2Ms), num(frame.baroKPa), num(frame.iacPosPct), num(frame.desiredIdleRpm),
            num(frame.batteryV), num(m.fuelLph), num(m.instantKmL), String(format: "%.6f", metrics.distanceKm),
            String(format: "%.6f", metrics.fuelUsedLEst), num(m.avgKmL), frame.rawPayloadHex, frame.rawResponse
        ]
        for i in 0..<65 {
            row.append(i < frame.payload.count ? String(frame.payload[i]) : "")
        }
        try writeLine(row.map(csvEscape).joined(separator: ","))
    }

    func appendEvent(_ event: String, profile: String, at now: Date = Date()) throws {
        guard handle != nil else { return }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var row = Array(repeating: "", count: 31 + 65)
        row[0] = iso.string(from: now)
        row[1] = String(Int64(now.timeIntervalSince1970 * 1000))
        row[2] = profile
        row[30] = event
        try writeLine(row.map(csvEscape).joined(separator: ","))
    }

    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        startedAt = nil
    }

    deinit { close() }

    private func writeLine(_ s: String) throws {
        guard let handle else { return }
        try handle.write(contentsOf: Data((s + "\n").utf8))
        try handle.synchronize()
    }

    private func num(_ v: Double?) -> String { v.map { String(format: "%.6f", $0) } ?? "" }
    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        return s
    }
}
