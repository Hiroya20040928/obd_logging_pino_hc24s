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

struct SuzukiBootstrapResult: Sendable {
    let probes: [ProbeResult]
    let ecuOnline: Bool
    let startCommunicationPositive: Bool
    let liveCommands: [String]
    let initPath: String
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

    /// SZ Viewer由来のELM327初期化系列．
    /// CAN専用ATコマンドはK-Lineでは実通信に影響しないため，cloneが"?"を返しても継続する．
    private let szViewerInit: [(String, Bool)] = [
        ("ATZ", true),
        ("ATE0", true),
        ("ATL0", true),
        ("ATS0", true),
        ("ATH0", true),
        ("ATAL", true),
        ("ATIB10", true),
        ("ATKW0", false),
        ("ATSW00", false),
        ("ATAT0", false),
        ("ATCAF1", false),
        ("ATCFC1", false),
        ("ATFCSM0", false),
        ("ATTP5", true),
        ("ATSH8111F1", true),
        ("ATST19", true)
    ]

    func initializeAdapter() async throws -> [ProbeResult] {
        var results: [ProbeResult] = []

        for (command, required) in szViewerInit {
            let timeout: TimeInterval = command == "ATZ" ? 4.0 : 2.5
            let raw = (try? await ble.send(command, timeout: timeout)) ?? ""

            let definition = ProbeDefinition(
                command: command,
                label: required ? "SZ_ELM_INIT_REQUIRED" : "SZ_ELM_INIT_OPTIONAL",
                repeatIfPositive: false
            )

            let classification = KWPFrameParser.classify(command: "", raw: raw)

            results.append(
                ProbeResult(
                    date: Date(),
                    definition: definition,
                    raw: raw,
                    classification: classification
                )
            )

            if command == "ATZ" {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }

            if required {
                let u = raw.uppercased()
                if u.contains("UNABLE TO CONNECT")
                    || u.contains("STOPPED")
                    || u.contains("ERROR")
                    || u.contains("?") {
                    throw HC24SError.adapterInitFailed(command)
                }
            }
        }

        return results
    }

    /// 重要:
    /// v3では最初の車両要求を3Eにしていた．
    /// v4ではKWP2000本来のStartCommunication(0x81)を先に送る．
    /// 現ELM cloneがATFI非対応なら，ATPC→ATTP5後の最初の81にELMの自動fast-initを担当させる．
    func bootstrapSuzuki1() async -> SuzukiBootstrapResult {
        var probes: [ProbeResult] = []
        var initPath = "ATFI"

        let fi = await sendAT("ATFI", label: "SZ_FAST_INIT", timeout: 5.0)
        probes.append(fi)

        if fi.classification.kind == .adapterError {
            initPath = "AUTO_FAST_INIT_FIRST_81"

            probes.append(await sendAT("ATPC", label: "SZ_FALLBACK_PROTOCOL_CLOSE", timeout: 2.0))
            probes.append(await sendAT("ATTP5", label: "SZ_FALLBACK_PROTOCOL5", timeout: 2.0))
            probes.append(await sendAT("ATSH8111F1", label: "SZ_FALLBACK_HEADER", timeout: 2.0))
            probes.append(await sendAT("ATST19", label: "SZ_FALLBACK_TIMEOUT", timeout: 2.0))

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // KWP2000 StartCommunication.
        // ATFI経路ならfast-init pulse後の最初のmessage，
        // fallback経路ならELMが最初のmessage直前にfast-initを自動実行する．
        let startCommunication = await sendProbe(
            ProbeDefinition(
                command: "81",
                label: "KWP_START_COMMUNICATION",
                repeatIfPositive: false
            ),
            timeout: 5.0
        )
        probes.append(startCommunication)

        let startOK =
            startCommunication.classification.kind == .positive
            && startCommunication.classification.responseSID == 0xC1

        let kw = await sendAT("ATKW", label: "SZ_KEYWORDS", timeout: 2.5)
        probes.append(kw)

        let tester = await sendProbe(
            ProbeDefinition(
                command: "3E",
                label: "TESTER_PRESENT_CONNECT",
                repeatIfPositive: true
            ),
            timeout: 4.0
        )
        probes.append(tester)

        let online = isTesterPresentPositive(tester)

        var liveCommands: [String] = []

        if online {
            // SZ Viewer reverse engineeringではEngine_KWP_00_Local = 21 00．
            // 別のSuzuki KWP実例では21 01が長いengine data blockを返す．
            // HA24Sではsession開始後に両方をread-onlyで確認し，肯定応答だけ採用する．
            for command in ["2100", "2101"] {
                let live = await readSuzukiLocalData(command: command)
                probes.append(live)
                if isSuzukiLocalPositive(live, command: command) {
                    liveCommands.append(command)
                }
            }
        }

        return SuzukiBootstrapResult(
            probes: probes,
            ecuOnline: online,
            startCommunicationPositive: startOK,
            liveCommands: liveCommands,
            initPath: initPath
        )
    }

    func keepAlive() async -> ProbeResult {
        await sendProbe(
            ProbeDefinition(
                command: "3E",
                label: "TESTER_PRESENT",
                repeatIfPositive: true
            ),
            timeout: 2.0
        )
    }

    func readSuzukiLocalData(command: String) async -> ProbeResult {
        let suffix = command == "2100" ? "00" : "01"
        return await sendProbe(
            ProbeDefinition(
                command: command,
                label: "SUZUKI1_ENGINE_LOCAL_\(suffix)",
                repeatIfPositive: true
            ),
            timeout: 2.5
        )
    }

    func readVoltage() async -> ProbeResult {
        await sendAT("ATRV", label: "ELM_VOLTAGE_UNTRUSTED", timeout: 2.5)
    }

    func readAdapterMetadata() async -> [ProbeResult] {
        var out: [ProbeResult] = []

        for command in ["ATI", "AT@1", "ATRV", "ATDP", "ATDPN", "ATKW"] {
            out.append(
                await sendAT(command, label: "ELM_META", timeout: 2.5)
            )
        }

        return out
    }

    func sendProbe(
        _ definition: ProbeDefinition,
        timeout: TimeInterval
    ) async -> ProbeResult {
        let raw = (try? await ble.send(
            definition.command,
            timeout: timeout
        )) ?? ""

        let classification = KWPFrameParser.classify(
            command: definition.command,
            raw: raw
        )

        return ProbeResult(
            date: Date(),
            definition: definition,
            raw: raw,
            classification: classification
        )
    }

    func isTesterPresentPositive(_ result: ProbeResult) -> Bool {
        if result.classification.kind == .positive,
           result.classification.responseSID == 0x7E {
            return true
        }

        return result.classification.frames.contains {
            $0.source == 0x11
                && $0.target == 0xF1
                && $0.service == 0x7E
        }
    }

    func isSuzukiLocalPositive(
        _ result: ProbeResult,
        command: String
    ) -> Bool {
        let request = KWPFrameParser.commandBytes(command)
        guard request.count >= 2,
              result.classification.kind == .positive,
              let payload = KWPFrameParser.responsePayload(
                command: command,
                raw: result.raw
              ),
              payload.count >= 2 else {
            return false
        }

        return payload[0] == 0x61 && payload[1] == request[1]
    }

    nonisolated static func isSafeReadOnly(_ command: String) -> Bool {
        let b = KWPFrameParser.commandBytes(command)
        guard let sid = b.first else { return false }

        let allow: Set<UInt8> = [
            0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x09, 0x0A,
            0x12, 0x13, 0x17, 0x18, 0x19, 0x1A,
            0x21, 0x22, 0x23, 0x24, 0x33, 0x3E, 0x81
        ]

        return allow.contains(sid)
    }

    private func sendAT(
        _ command: String,
        label: String,
        timeout: TimeInterval
    ) async -> ProbeResult {
        let raw = (try? await ble.send(
            command,
            timeout: timeout
        )) ?? ""

        return ProbeResult(
            date: Date(),
            definition: ProbeDefinition(
                command: command,
                label: label,
                repeatIfPositive: false
            ),
            raw: raw,
            classification: KWPFrameParser.classify(
                command: "",
                raw: raw
            )
        )
    }
}
