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
        }

        let u = raw.uppercased()
        if u.contains("NO DATA") || u.contains("UNABLE TO CONNECT") || u.contains("BUS ERROR") {
            return KWPClassification(kind: .noData, requestSID: requestSID, responseSID: nil, nrc: nil, frames: frames)
        }
        if u.contains("?") || u.contains("ERROR") {
            return KWPClassification(kind: .adapterError, requestSID: requestSID, responseSID: nil, nrc: nil, frames: frames)
        }
        if !frames.isEmpty {
            return KWPClassification(kind: .otherFrame, requestSID: requestSID, responseSID: frames.first?.service, nrc: nil, frames: frames)
        }
        return KWPClassification(kind: .noKWPFrame, requestSID: requestSID, responseSID: nil, nrc: nil, frames: [])
    }

    private static func byteCandidates(from line: String) -> [[UInt8]] {
        var candidates: [[UInt8]] = []

        let pairRegex = try! NSRegularExpression(pattern: "(?i)(?<![0-9A-F])[0-9A-F]{2}(?![0-9A-F])")
        let ns = line as NSString
        let pairs = pairRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap {
            UInt8(ns.substring(with: $0.range), radix: 16)
        }
        if pairs.count >= 5 {
            candidates.append(pairs)
        }

        let compactRegex = try! NSRegularExpression(pattern: "(?i)(?<![0-9A-F])[0-9A-F]{10,}(?![0-9A-F])")
        for match in compactRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: match.range)
            if s.count % 2 == 0 {
                let b = commandBytes(s)
                if b.count >= 5 { candidates.append(b) }
            }
        }

        return candidates
    }

    private static func frames(from bytes: [UInt8]) -> [KWPFrame] {
        guard bytes.count >= 5 else { return [] }
        var result: [KWPFrame] = []
        for start in 0..<bytes.count {
            let format = bytes[start]
            let payloadLength = Int(format & 0x3F)
            guard payloadLength >= 1 else { continue }
            let totalLength = payloadLength + 4
            guard start + totalLength <= bytes.count else { continue }
            let frameBytes = Array(bytes[start..<(start + totalLength)])
            let calculated = frameBytes.dropLast().reduce(0) { ($0 + Int($1)) & 0xFF }
            guard UInt8(calculated) == frameBytes.last else { continue }
            let payload = Array(frameBytes[3..<(3 + payloadLength)])
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
        default: return "unknown"
        }
    }
}
