import Foundation

struct KWPFrame: Sendable, Equatable {
    let bytes: [UInt8]
    let payload: [UInt8]

    var format: UInt8 { bytes[0] }
    var target: UInt8 { bytes.count > 1 ? bytes[1] : 0 }
    var source: UInt8 { bytes.count > 2 ? bytes[2] : 0 }
    var service: UInt8? { payload.first }
    var checksum: UInt8 { bytes.last ?? 0 }

    var hex: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var payloadHex: String {
        payload.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var isNegativeResponse: Bool {
        payload.first == 0x7F && payload.count >= 3
    }

    var negativeRequestSID: UInt8? {
        isNegativeResponse ? payload[1] : nil
    }

    var negativeResponseCode: UInt8? {
        isNegativeResponse ? payload[2] : nil
    }

    func isPositiveResponse(to requestSID: UInt8) -> Bool {
        guard let service else { return false }
        return service == requestSID &+ 0x40
    }
}

enum KWPFrameParser {
    static func parseAll(_ raw: String) -> [KWPFrame] {
        var output: [KWPFrame] = []
        var seen = Set<String>()
        let lines = raw.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")

        for line in lines {
            for candidate in byteCandidates(from: line) {
                for frame in frames(from: candidate) {
                    if seen.insert(frame.hex).inserted {
                        output.append(frame)
                    }
                }
            }
        }
        return output
    }

    static func commandBytes(_ command: String) -> [UInt8] {
        let cleaned = command.filter { $0.isHexDigit }
        guard cleaned.count >= 2, cleaned.count % 2 == 0 else { return [] }

        var bytes: [UInt8] = []
        var i = cleaned.startIndex

        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            guard let b = UInt8(String(cleaned[i..<j]), radix: 16) else { return [] }
            bytes.append(b)
            i = j
        }

        return bytes
    }

    /// ATH0/ATS0で返るpayload-only応答を抽出する．
    /// "NO DATA"や"BUS INIT:"等の文字列をhexとして誤読しないよう，
    /// 行全体がhex+空白だけのものに限定する．
    static func payloadCandidates(_ raw: String) -> [[UInt8]] {
        let separators = CharacterSet(charactersIn: "\r\n>")
        return raw.components(separatedBy: separators).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }

            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF ")
            guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

            let compact = t.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 2, compact.count % 2 == 0 else { return nil }
            return commandBytes(compact)
        }
    }

    static func responsePayload(command: String, raw: String) -> [UInt8]? {
        let req = commandBytes(command)
        guard let sid = req.first else { return nil }

        for f in parseAll(raw) {
            if f.isPositiveResponse(to: sid) || f.negativeRequestSID == sid {
                return f.payload
            }
        }

        for p in payloadCandidates(raw) {
            guard let first = p.first else { continue }

            if first == sid &+ 0x40 {
                return p
            }

            if p.count >= 3, p[0] == 0x7F, p[1] == sid {
                return p
            }
        }

        return nil
    }

    static func classify(command: String, raw: String) -> KWPClassification {
        let request = commandBytes(command)
        let requestSID = request.first
        let frames = parseAll(raw)

        if let sid = requestSID {
            if let f = frames.first(where: { $0.negativeRequestSID == sid }) {
                return KWPClassification(
                    kind: .negative,
                    requestSID: sid,
                    responseSID: f.service,
                    nrc: f.negativeResponseCode,
                    frames: frames
                )
            }

            if let f = frames.first(where: { $0.isPositiveResponse(to: sid) }) {
                return KWPClassification(
                    kind: .positive,
                    requestSID: sid,
                    responseSID: f.service,
                    nrc: nil,
                    frames: frames
                )
            }

            // v4: SZ Viewerと同じATH0/ATS0運用に対応する．
            for p in payloadCandidates(raw) {
                guard let first = p.first else { continue }

                if p.count >= 3, p[0] == 0x7F, p[1] == sid {
                    return KWPClassification(
                        kind: .negative,
                        requestSID: sid,
                        responseSID: 0x7F,
                        nrc: p[2],
                        frames: frames
                    )
                }

                if first == sid &+ 0x40 {
                    return KWPClassification(
                        kind: .positive,
                        requestSID: sid,
                        responseSID: first,
                        nrc: nil,
                        frames: frames
                    )
                }
            }
        }

        let u = raw.uppercased()

        if u.contains("NO DATA")
            || u.contains("UNABLE TO CONNECT")
            || u.contains("BUS ERROR")
            || u.contains("BUS INIT: ERROR") {
            return KWPClassification(
                kind: .noData,
                requestSID: requestSID,
                responseSID: nil,
                nrc: nil,
                frames: frames
            )
        }

        if u.contains("?") || u.contains("ERROR") {
            return KWPClassification(
                kind: .adapterError,
                requestSID: requestSID,
                responseSID: nil,
                nrc: nil,
                frames: frames
            )
        }

        if !frames.isEmpty {
            return KWPClassification(
                kind: .otherFrame,
                requestSID: requestSID,
                responseSID: frames.first?.service,
                nrc: nil,
                frames: frames
            )
        }

        return KWPClassification(
            kind: .noKWPFrame,
            requestSID: requestSID,
            responseSID: nil,
            nrc: nil,
            frames: []
        )
    }

    private static func byteCandidates(from line: String) -> [[UInt8]] {
        var candidates: [[UInt8]] = []

        let pairRegex = try! NSRegularExpression(
            pattern: "(?i)(?<![0-9A-F])[0-9A-F]{2}(?![0-9A-F])"
        )
        let ns = line as NSString

        let pairs = pairRegex.matches(
            in: line,
            range: NSRange(location: 0, length: ns.length)
        ).compactMap {
            UInt8(ns.substring(with: $0.range), radix: 16)
        }

        if pairs.count >= 5 {
            candidates.append(pairs)
        }

        let compactRegex = try! NSRegularExpression(
            pattern: "(?i)(?<![0-9A-F])[0-9A-F]{10,}(?![0-9A-F])"
        )

        for match in compactRegex.matches(
            in: line,
            range: NSRange(location: 0, length: ns.length)
        ) {
            let s = ns.substring(with: match.range)

            if s.count % 2 == 0 {
                let b = commandBytes(s)
                if b.count >= 5 {
                    candidates.append(b)
                }
            }
        }

        return candidates
    }

    private static func frames(from bytes: [UInt8]) -> [KWPFrame] {
        guard bytes.count >= 5 else { return [] }

        var result: [KWPFrame] = []

        for start in 0..<bytes.count {
            let format = bytes[start]
            let shortPayloadLength = Int(format & 0x3F)

            if shortPayloadLength >= 1 {
                let totalLength = shortPayloadLength + 4
                guard start + totalLength <= bytes.count else { continue }

                let frameBytes = Array(bytes[start..<(start + totalLength)])
                let calculated = frameBytes.dropLast().reduce(0) {
                    ($0 + Int($1)) & 0xFF
                }

                guard UInt8(calculated) == frameBytes.last else { continue }

                let payload = Array(
                    frameBytes[3..<(3 + shortPayloadLength)]
                )
                result.append(KWPFrame(bytes: frameBytes, payload: payload))
                continue
            }

            // KWP long format:
            // format(low6=0), target, source, explicitLength, payload..., checksum
            guard start + 5 <= bytes.count else { continue }

            let explicitLength = Int(bytes[start + 3])
            guard explicitLength >= 1 else { continue }

            let totalLength = explicitLength + 5
            guard start + totalLength <= bytes.count else { continue }

            let frameBytes = Array(bytes[start..<(start + totalLength)])
            let calculated = frameBytes.dropLast().reduce(0) {
                ($0 + Int($1)) & 0xFF
            }

            guard UInt8(calculated) == frameBytes.last else { continue }

            let payload = Array(
                frameBytes[(start - start + 4)..<(4 + explicitLength)]
            )
            result.append(KWPFrame(bytes: frameBytes, payload: payload))
        }

        return result
    }
}

struct KWPClassification: Sendable {
    enum Kind: String, Sendable {
        case positive
        case negative
        case noData
        case adapterError
        case otherFrame
        case noKWPFrame
    }

    let kind: Kind
    let requestSID: UInt8?
    let responseSID: UInt8?
    let nrc: UInt8?
    let frames: [KWPFrame]

    var summary: String {
        switch kind {
        case .positive:
            return "POSITIVE"
        case .negative:
            if let nrc {
                return "NEGATIVE NRC=\(String(format: "%02X", nrc)) \(Self.nrcName(nrc))"
            }
            return "NEGATIVE"
        case .noData:
            return "NO_DATA"
        case .adapterError:
            return "ADAPTER_ERROR"
        case .otherFrame:
            return "OTHER_KWP_FRAME"
        case .noKWPFrame:
            return "NO_KWP_FRAME"
        }
    }

    static func nrcName(_ nrc: UInt8) -> String {
        switch nrc {
        case 0x10: return "generalReject"
        case 0x11: return "serviceNotSupported"
        case 0x12: return "subFunctionNotSupportedOrInvalidFormat"
        case 0x21: return "busyRepeatRequest"
        case 0x22: return "conditionsNotCorrect"
        case 0x31: return "requestOutOfRange"
        case 0x33: return "securityAccessDenied"
        case 0x78: return "responsePending"
        case 0x80: return "serviceNotSupportedInActiveSession"
        default: return "unknown"
        }
    }
}

/// SZ ViewerのEngine_KWP_00_Local系で使われる既知の61 00ブロック用．
/// HA24Sで同一offsetであることは現車データで確認するまで確定しないため，
/// UI/CSVでは必ず「SZ_GENERIC_MAP」として記録する．
struct SuzukiGenericLiveSnapshot: Sendable {
    let timestamp: Date
    let rpm: Double
    let coolantC: Int
    let speedKmh: Int
    let throttlePct: Double
    let intakeC: Int
    let baroKpa: Double
    let batteryV: Double
    let engineLoadPct: Double
    let ignitionAdvanceDeg: Int
    let mapKpa: Int
    let mafGps: Double
    let o2B1S1V: Double
    let stft1Pct: Double
    let ltft1Pct: Double
    let fuelPulse1Ms: Double
    let fuelPulse2Ms: Double
    let desiredIdleRPM: Int
    let iacPct: Double
    let dataLength: Int

    static func decode2100(raw: String, date: Date = Date()) -> SuzukiGenericLiveSnapshot? {
        guard let payload = KWPFrameParser.responsePayload(command: "2100", raw: raw),
              payload.count >= 52,
              payload[0] == 0x61,
              payload[1] == 0x00 else {
            return nil
        }

        let b = Array(payload.dropFirst(2))
        guard b.count >= 50 else { return nil }

        func word(_ hi: Int, _ lo: Int) -> Int {
            (Int(b[hi]) << 8) | Int(b[lo])
        }

        return SuzukiGenericLiveSnapshot(
            timestamp: date,
            rpm: Double(word(20, 21)) * 0.25,
            coolantC: Int(b[14]) - 40,
            speedKmh: Int(b[22]),
            throttlePct: Double(b[27]) * 0.392,
            intakeC: Int(b[24]) - 40,
            baroKpa: Double(b[41]) * 0.5,
            batteryV: Double(b[49]) * 0.0784,
            engineLoadPct: Double(b[13]) * (100.0 / 255.0),
            ignitionAdvanceDeg: Int(b[23]) - 64,
            mapKpa: Int(b[19]),
            mafGps: Double(word(25, 26)) * 0.01,
            o2B1S1V: Double(b[29]) * 0.005,
            stft1Pct: Double(b[15]) * 0.78125 - 100.0,
            ltft1Pct: Double(b[16]) * 0.78125 - 100.0,
            fuelPulse1Ms: Double(word(37, 38)) * 0.001,
            fuelPulse2Ms: Double(word(39, 40)) * 0.001,
            desiredIdleRPM: Int(b[35]) * 10,
            iacPct: Double(b[42]) * 0.392,
            dataLength: b.count
        )
    }

    var sanityScore: Int {
        var score = 0
        if rpm >= 0 && rpm <= 9000 { score += 1 }
        if coolantC >= -40 && coolantC <= 150 { score += 1 }
        if speedKmh >= 0 && speedKmh <= 200 { score += 1 }
        if throttlePct >= 0 && throttlePct <= 100.5 { score += 1 }
        if intakeC >= -40 && intakeC <= 120 { score += 1 }
        if batteryV >= 7 && batteryV <= 18 { score += 1 }
        return score
    }
}
