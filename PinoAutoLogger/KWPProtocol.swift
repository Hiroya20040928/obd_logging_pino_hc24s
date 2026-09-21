import Foundation

struct ProbeDefinition: Sendable, Hashable {
    let command: String
    let label: String
    let repeatIfPositive: Bool
}

struct ProbeResult: Sendable {
    let date: Date
    let definition: ProbeDefinition
    let raw: String
    let classification: KWPClassification
}

enum HC24SError: Error {
    case adapterInitFailed(String)
    case ecuNotResponding
}

@MainActor
final class KWPProtocol {
    private let ble: ELMBluetooth

    init(ble: ELMBluetooth) {
        self.ble = ble
    }

    // 実車HC24Sで手動確認できた最小系列．ATFIはこのv2.1互換機が「?」を返すため使用しない．
    private let initCommands = [
        "ATZ",
        "ATE0",
        "ATL0",
        "ATS1",
        "ATH1",
        "ATAL",
        "ATIB10",
        "ATSP5",
        "ATSH8111F1",
        "ATST64"
    ]

    func initializeAdapter() async throws -> [ProbeResult] {
        var results: [ProbeResult] = []
        for command in initCommands {
            let timeout: TimeInterval = command == "ATZ" ? 4.0 : 2.5
            let raw = (try? await ble.send(command, timeout: timeout)) ?? ""
            let definition = ProbeDefinition(command: command, label: "ELM_INIT", repeatIfPositive: false)
            let c = KWPFrameParser.classify(command: "", raw: raw)
            results.append(ProbeResult(date: Date(), definition: definition, raw: raw, classification: c))

            if command == "ATZ" {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }

            let u = raw.uppercased()
            if u.contains("UNABLE TO CONNECT") || u.contains("STOPPED") || u.contains("ERROR") || u.contains("?") {
                throw HC24SError.adapterInitFailed(command)
            }
        }
        return results
    }

    func readAdapterMetadata() async -> [ProbeResult] {
        var out: [ProbeResult] = []
        for command in ["ATI", "AT@1", "ATRV", "ATDP", "ATDPN"] {
            let raw = (try? await ble.send(command, timeout: 2.5)) ?? ""
            let d = ProbeDefinition(command: command, label: "ELM_META", repeatIfPositive: false)
            out.append(ProbeResult(date: Date(), definition: d, raw: raw,
                                   classification: KWPFrameParser.classify(command: "", raw: raw)))
        }
        return out
    }

    // ATSP5を選択したELM327は，最初の車両要求時に自動BUS INITを行える．
    // 実車では3E -> 81 F1 11 7E 01 が成立したため，これをECU online判定に使う．
    func establishECU() async -> ProbeResult? {
        let d = ProbeDefinition(command: "3E", label: "TESTER_PRESENT_CONNECT", repeatIfPositive: true)
        for _ in 0..<3 {
            let r = await sendProbe(d, timeout: 4.0)
            if isTesterPresentPositive(r) {
                return r
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        return nil
    }

    func keepAlive() async -> ProbeResult {
        await sendProbe(ProbeDefinition(command: "3E", label: "TESTER_PRESENT", repeatIfPositive: true), timeout: 2.0)
    }

    func readVoltage() async -> ProbeResult {
        let command = "ATRV"
        let raw = (try? await ble.send(command, timeout: 2.5)) ?? ""
        let d = ProbeDefinition(command: command, label: "ELM_VOLTAGE", repeatIfPositive: false)
        return ProbeResult(date: Date(), definition: d, raw: raw,
                           classification: KWPFrameParser.classify(command: "", raw: raw))
    }

    func runSafeDiscovery(custom: [ProbeDefinition]) async -> [ProbeResult] {
        var results: [ProbeResult] = []
        let plan = Self.safeBuiltInPlan + custom.filter { Self.isSafeReadOnly($0.command) }

        for d in plan {
            if Task.isCancelled { break }
            let r = await sendProbe(d, timeout: 2.0)
            results.append(r)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return results
    }

    func poll(_ definitions: [ProbeDefinition]) async -> [ProbeResult] {
        var out: [ProbeResult] = []
        for d in definitions.prefix(8) where d.repeatIfPositive {
            out.append(await sendProbe(d, timeout: 1.8))
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return out
    }

    func sendProbe(_ definition: ProbeDefinition, timeout: TimeInterval) async -> ProbeResult {
        let raw = (try? await ble.send(definition.command, timeout: timeout)) ?? ""
        let c = KWPFrameParser.classify(command: definition.command, raw: raw)
        return ProbeResult(date: Date(), definition: definition, raw: raw, classification: c)
    }

    func isTesterPresentPositive(_ result: ProbeResult) -> Bool {
        result.classification.frames.contains {
            $0.source == 0x11 && $0.target == 0xF1 && $0.service == 0x7E
        }
    }

    static let safeBuiltInPlan: [ProbeDefinition] = [
        // SAE OBDの読み取り系．HC24Sでは01がNRC11確認済みだが，read-only範囲だけ記録する．
        ProbeDefinition(command: "0100", label: "OBD_MODE01_SUPPORTED_PIDS", repeatIfPositive: false),
        ProbeDefinition(command: "03", label: "OBD_READ_DTC", repeatIfPositive: false),
        ProbeDefinition(command: "0900", label: "OBD_MODE09_SUPPORTED", repeatIfPositive: false),
        ProbeDefinition(command: "0902", label: "OBD_VIN", repeatIfPositive: false),

        // KWP2000の読み取り系サービスだけ．書込み/reset/control/securityは一切含めない．
        ProbeDefinition(command: "12", label: "KWP_READ_FREEZE_FRAME_SERVICE_PROBE", repeatIfPositive: false),
        ProbeDefinition(command: "13", label: "KWP_READ_DTC_SERVICE_PROBE", repeatIfPositive: false),
        ProbeDefinition(command: "17", label: "KWP_READ_DTC_STATUS_SERVICE_PROBE", repeatIfPositive: false),
        ProbeDefinition(command: "18", label: "KWP_READ_DTC_BY_STATUS_SERVICE_PROBE", repeatIfPositive: false),
        ProbeDefinition(command: "1800FF00", label: "KWP_READ_ALL_DTC_BY_STATUS", repeatIfPositive: false),
        ProbeDefinition(command: "1A", label: "KWP_READ_ECU_ID_SERVICE_PROBE", repeatIfPositive: false),
        ProbeDefinition(command: "1A80", label: "KWP_READ_ECU_ID_80", repeatIfPositive: false),
        ProbeDefinition(command: "1A8E", label: "SUZUKI_READ_ECU_ID_8E", repeatIfPositive: false),
        ProbeDefinition(command: "1A90", label: "KWP_READ_ECU_ID_VIN", repeatIfPositive: false),
        ProbeDefinition(command: "1A91", label: "SUZUKI_READ_ECU_ID_91", repeatIfPositive: false),
        ProbeDefinition(command: "1A96", label: "KWP_READ_ECU_ID_CALIBRATION", repeatIfPositive: false),
        ProbeDefinition(command: "1A9A", label: "SUZUKI_READ_ECU_ID_9A", repeatIfPositive: false),

        // Suzukiの他ECU/世代で実例があるread-only候補．
        // HC24S現車ではService 21/22/23はNRC11確認済み．結果をrawで再確認する目的で1回だけ送る．
        ProbeDefinition(command: "21", label: "KWP_LOCAL_ID_SERVICE_PROBE", repeatIfPositive: false),
        ProbeDefinition(command: "2100", label: "SUZUKI_LOCAL_00", repeatIfPositive: true),
        ProbeDefinition(command: "2101", label: "SUZUKI_LOCAL_01", repeatIfPositive: true),
        ProbeDefinition(command: "2103", label: "SUZUKI_LOCAL_03", repeatIfPositive: true),
        ProbeDefinition(command: "2108", label: "SUZUKI_LOCAL_08", repeatIfPositive: true),
        ProbeDefinition(command: "22", label: "KWP_IDENTIFIER_SERVICE_PROBE", repeatIfPositive: false),
        ProbeDefinition(command: "22F190", label: "KWP_VIN_IDENTIFIER", repeatIfPositive: false),
        ProbeDefinition(command: "23", label: "KWP_READ_MEMORY_SERVICE_PROBE", repeatIfPositive: false)
    ]

    // custom planでも安全側に固定する．未知のメーカー独自SID総当たりは行わない．
    static func isSafeReadOnly(_ command: String) -> Bool {
        let b = KWPFrameParser.commandBytes(command)
        guard let sid = b.first else { return false }
        let allow: Set<UInt8> = [
            0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x09, 0x0A,
            0x12, 0x13, 0x17, 0x18, 0x19, 0x1A,
            0x21, 0x22, 0x23, 0x24, 0x33, 0x3E
        ]
        return allow.contains(sid)
    }
}
