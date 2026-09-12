import Foundation

struct KWPConnection {
    let profile: String
    let firstFrame: EngineFrame
}

@MainActor
final class KWPProtocol {
    private let ble: ELMBluetooth
    init(ble: ELMBluetooth) { self.ble = ble }

    func identifyAdapter() async -> [String: String] {
        var r: [String: String] = [:]
        for c in ["ATI", "AT@1", "ATRV"] { r[c] = (try? await ble.send(c, timeout: 2.0)) ?? "" }
        return r
    }

    func connectEngine(fastInitAttempts: Int = 1) async throws -> KWPConnection {
        let common: [(String, Bool)] = [
            ("ATZ", true), ("ATE0", true), ("ATL0", true), ("ATS0", true), ("ATH0", true),
            ("ATAL", true), ("ATIB10", true), ("ATKW0", true), ("ATSW00", true), ("ATAT0", true),
            ("ATCAF1", false), ("ATCFC1", false), ("ATFCSM0", false)
        ]
        for protocolCommand in ["ATTP5", "ATSP5"] {
            var failed = false
            for (cmd, critical) in common {
                let raw = (try? await ble.send(cmd, timeout: cmd == "ATZ" ? 4.0 : 2.0)) ?? ""
                if cmd == "ATZ" { try? await Task.sleep(nanoseconds: 700_000_000) }
                if critical && bad(raw) { failed = true; break }
            }
            if failed { continue }
            for cmd in [protocolCommand, "ATSH8111F1", "ATST19"] {
                let raw = (try? await ble.send(cmd, timeout: 3.0)) ?? ""
                if bad(raw) { failed = true; break }
            }
            if failed { continue }
            var fiOK = false
            for attempt in 0..<max(1, fastInitAttempts) {
                let raw = (try? await ble.send("ATFI", timeout: 5.0)) ?? ""
                if !bad(raw) { fiOK = true; break }
                if attempt + 1 < max(1, fastInitAttempts) { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
            if !fiOK { continue }
            _ = try? await ble.send("ATKW", timeout: 2.0)
            _ = try? await ble.send("3E", timeout: 2.0)
            let raw = (try? await ble.send("2100", timeout: 3.0)) ?? ""
            if let f = EngineFrame.decode(raw) {
                return KWPConnection(profile: protocolCommand == "ATTP5" ? "Suzuki_KWP_ATTP5" : "Suzuki_KWP_ATSP5", firstFrame: f)
            }
        }
        throw KWPError.noPositive6100
    }

    func readFrame() async -> EngineFrame? {
        _ = try? await ble.send("3E", timeout: 1.5)
        guard let raw = try? await ble.send("2100", timeout: 2.0) else { return nil }
        return EngineFrame.decode(raw)
    }

    private func bad(_ raw: String) -> Bool {
        let u = raw.uppercased()
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || u.contains("?") || u.contains("ERROR") || u.contains("UNABLE TO CONNECT") || u.contains("STOPPED")
    }
}

enum KWPError: Error { case noPositive6100 }
