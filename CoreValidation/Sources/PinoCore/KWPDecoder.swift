import Foundation

struct EngineFrame: Sendable {
    let rawResponse: String
    let payload: [UInt8]
    let engineLoadPct: Double?
    let coolantC: Double?
    let stft1Pct: Double?
    let ltft1Pct: Double?
    let stft2Pct: Double?
    let ltft2Pct: Double?
    let mapKPa: Double?
    let rpm: Double?
    let speedKmh: Double?
    let ignitionAdvanceDeg: Double?
    let iatC: Double?
    let mafGps: Double?
    let throttlePct: Double?
    let o2B1S1V: Double?
    let desiredIdleRpm: Double?
    let tpsV: Double?
    let fuelPulse1Ms: Double?
    let fuelPulse2Ms: Double?
    let baroKPa: Double?
    let iacPosPct: Double?
    let batteryV: Double?

    var rawPayloadHex: String { payload.map { String(format: "%02X", $0) }.joined() }

    static func decode(_ raw: String) -> EngineFrame? {
        let bytes = extractHexBytes(raw)
        guard let i = markerIndex(bytes, [0x61, 0x00]) else { return nil }
        let p = Array(bytes.dropFirst(i + 2))
        guard p.count >= 50 else { return nil }
        func u16(_ i: Int) -> Int { (Int(p[i]) << 8) | Int(p[i + 1]) }
        return EngineFrame(
            rawResponse: raw,
            payload: p,
            engineLoadPct: Double(p[13]) * 100.0 / 255.0,
            coolantC: Double(Int(p[14]) - 40),
            stft1Pct: Double(p[15]) * 0.78125 - 100.0,
            ltft1Pct: Double(p[16]) * 0.78125 - 100.0,
            stft2Pct: Double(p[17]) * 0.78125 - 100.0,
            ltft2Pct: Double(p[18]) * 0.78125 - 100.0,
            mapKPa: Double(p[19]),
            rpm: Double(u16(20)) * 0.25,
            speedKmh: Double(p[22]),
            ignitionAdvanceDeg: Double(Int(p[23]) - 64),
            iatC: Double(Int(p[24]) - 40),
            mafGps: Double(u16(25)) * 0.01,
            throttlePct: Double(p[27]) * 0.392,
            o2B1S1V: Double(p[29]) * 0.005,
            desiredIdleRpm: Double(p[35]) * 10.0,
            tpsV: Double(p[36]) * 0.0196,
            fuelPulse1Ms: Double(u16(37)) * 0.001,
            fuelPulse2Ms: Double(u16(39)) * 0.001,
            baroKPa: Double(p[41]) * 0.5,
            iacPosPct: Double(p[42]) * 0.392,
            batteryV: Double(p[49]) * 0.0784
        )
    }

    private static func markerIndex(_ data: [UInt8], _ marker: [UInt8]) -> Int? {
        guard data.count >= marker.count else { return nil }
        for i in 0...(data.count - marker.count) where Array(data[i..<(i + marker.count)]) == marker { return i }
        return nil
    }

    private static func extractHexBytes(_ raw: String) -> [UInt8] {
        // ATS0 removes spaces, so valid ELM frames may be one long hex string.
        // Extract all hex pairs and then locate the positive-response marker 61 00.
        // Any incidental pairs before 61 00 (echo/SEARCHING text) are ignored by marker search.
        let regex = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{2}")
        let ns = raw as NSString
        return regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            UInt8(ns.substring(with: m.range), radix: 16)
        }
    }
}

struct TripMetrics: Sendable {
    var lastDate: Date?
    var distanceKm = 0.0
    var fuelUsedLEst = 0.0

    mutating func update(at now: Date, frame: EngineFrame) -> (fuelLph: Double?, instantKmL: Double?, avgKmL: Double?) {
        let fuelLph: Double? = frame.mafGps.map { maf in
            guard maf >= 0 else { return 0 }
            return (maf / 14.7) * 3600.0 / 745.0
        }
        if let prev = lastDate {
            let hours = max(now.timeIntervalSince(prev), 0) / 3600.0
            if let speed = frame.speedKmh { distanceKm += speed * hours }
            if let fuelLph { fuelUsedLEst += fuelLph * hours }
        }
        lastDate = now
        let instant = (frame.speedKmh != nil && fuelLph != nil && fuelLph! > 1e-9) ? frame.speedKmh! / fuelLph! : nil
        let avg = fuelUsedLEst > 1e-9 ? distanceKm / fuelUsedLEst : nil
        return (fuelLph, instant, avg)
    }
}
