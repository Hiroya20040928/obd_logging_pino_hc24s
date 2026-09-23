import Foundation
import SwiftUI

@MainActor
final class AutoLoggerController: ObservableObject {
    @Published var state = "待機"
    @Published var ecuStatus = "未確認"
    @Published var adapterVoltage = "—"
    @Published var positiveProbeCount = 0
    @Published var lastKWPFrame = "—"
    @Published var currentCSVURL: URL?
    @Published var currentTextURL: URL?
    @Published var lastCSVURL: URL?
    @Published var lastTextURL: URL?

    @Published var autoLoggingEnabled: Bool =
        UserDefaults.standard.object(forKey: "autoLoggingEnabledV3") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoLoggingEnabled, forKey: "autoLoggingEnabledV3")
            if autoLoggingEnabled {
                startWorkerIfNeeded()
            } else {
                finishSession(reason: "AUTOLOG_DISABLED")
            }
        }
    }

    let ble = ELMBluetooth()
    private lazy var kwp = KWPProtocol(ble: ble)
    private let writer = DiagnosticLogWriter()

    private var worker: Task<Void, Never>?
    private var preSessionTransport: [TransportRecord] = []
    private var consecutiveECUFailures = 0
    private var activeReadProbes: [ProbeDefinition] = []

    init() {
        writer.ensureProbePlanExists()

        ble.traceSink = { [weak self] record in
            guard let self else { return }
            if self.writer.isOpen {
                self.writer.appendTransport(record)
            } else {
                self.preSessionTransport.append(record)
                if self.preSessionTransport.count > 300 {
                    self.preSessionTransport.removeFirst(self.preSessionTransport.count - 300)
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .elmReady, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startWorkerIfNeeded() }
        }

        NotificationCenter.default.addObserver(forName: .elmDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.finishSession(reason: "BLE_DISCONNECTED")
                self?.ecuStatus = "BLE切断"
            }
        }
    }

    func start() {
        ble.reconnect()
        startWorkerIfNeeded()
    }

    func setupAccessory() {
        ble.showAccessoryPicker()
    }

    func reconnect() {
        ble.reconnect()
        startWorkerIfNeeded()
    }


    private func startWorkerIfNeeded() {
        guard worker == nil, autoLoggingEnabled else { return }

        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }

            while !Task.isCancelled {
                if !self.autoLoggingEnabled {
                    self.state = "自動ロギングOFF"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                guard self.ble.ready else {
                    self.state = "ELM327 BLE接続待ち"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                self.state = "ELM327初期化中"
                do {
                    let initResults = try await self.kwp.initializeAdapter()

                    self.state = "HC24S ECU確認中"
                    guard let connectResult = await self.kwp.establishECU() else {
                        throw HC24SError.ecuNotResponding
                    }

                    try self.beginSession()
                    initResults.forEach { self.writer.appendProbe($0) }
                    self.writer.appendProbe(connectResult)

                    self.ecuStatus = "ECU 0x11 online / TesterPresent OK"
                    self.consecutiveECUFailures = 0
                    self.updateLastFrame(connectResult)

                    let metadata = await self.kwp.readAdapterMetadata()
                    metadata.forEach {
                        self.writer.appendProbe($0)
                        if $0.definition.command == "ATRV" {
                            self.adapterVoltage = Self.extractVoltage($0.raw) ?? "取得不能"
                        }
                    }

                    self.state = "安全read-only探索中"
                    let custom = self.writer.loadCustomProbePlan()
                    let discovery = await self.kwp.runSafeDiscovery(custom: custom)
                    discovery.forEach {
                        self.writer.appendProbe($0)
                        self.updateLastFrame($0)
                    }

                    let positive = discovery.filter { $0.classification.kind == .positive }
                    self.positiveProbeCount = positive.count

                    var unique = Set<String>()
                    self.activeReadProbes = positive
                        .map(\.definition)
                        .filter { $0.repeatIfPositive && unique.insert($0.command).inserted }

                    self.writer.appendEvent(
                        "DISCOVERY_COMPLETE",
                        note: "positive=\(self.positiveProbeCount), repeatable=\(self.activeReadProbes.map(\.command).joined(separator: "|"))"
                    )

                    self.state = "ECU raw自動記録中"
                    await self.liveLoop()
                } catch {
                    self.finishSession(reason: "CONNECT_OR_INIT_FAILED")
                    self.ecuStatus = "ECU応答未確認"
                    self.state = "5秒後に自動再探索"
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func liveLoop() async {
        var voltageCounter = 0

        while ble.ready && autoLoggingEnabled && !Task.isCancelled {
            let keep = await kwp.keepAlive()
            writer.appendProbe(keep)
            updateLastFrame(keep)

            if kwp.isTesterPresentPositive(keep) {
                consecutiveECUFailures = 0
                ecuStatus = "ECU 0x11 online"
            } else {
                consecutiveECUFailures += 1
                if consecutiveECUFailures >= 4 {
                    ecuStatus = "ECU無応答"
                    finishSession(reason: "ECU_NO_RESPONSE_4X")
                    return
                }
            }

            if !activeReadProbes.isEmpty {
                let polled = await kwp.poll(activeReadProbes)
                polled.forEach {
                    writer.appendProbe($0)
                    updateLastFrame($0)
                }
            }

            voltageCounter += 1
            if voltageCounter >= 10 {
                voltageCounter = 0
                let voltage = await kwp.readVoltage()
                writer.appendProbe(voltage)
                adapterVoltage = Self.extractVoltage(voltage.raw) ?? adapterVoltage
            }

            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        finishSession(reason: "BLE_OR_AUTOLOG_STOP")
    }

    private func beginSession() throws {
        if writer.isOpen { return }
        let urls = try writer.start()
        currentCSVURL = urls.0
        currentTextURL = urls.1

        for record in preSessionTransport {
            writer.appendTransport(record)
        }
        preSessionTransport.removeAll(keepingCapacity: true)
        writer.appendEvent("ECU_ONLINE_CONFIRMED", note: "3E -> 7E")
    }

    private func finishSession(reason: String) {
        guard writer.isOpen else { return }
        writer.appendEvent("SESSION_END", note: reason)
        lastCSVURL = writer.csvURL
        lastTextURL = writer.textURL
        writer.close()
        currentCSVURL = nil
        currentTextURL = nil
        activeReadProbes = []
        positiveProbeCount = 0
    }

    private func updateLastFrame(_ r: ProbeResult) {
        if let frame = r.classification.frames.last {
            lastKWPFrame = frame.hex
        }
    }

    private static func extractVoltage(_ raw: String) -> String? {
        let regex = try? NSRegularExpression(pattern: #"([0-9]{1,2}(?:\.[0-9]+)?)\s*V"#, options: [.caseInsensitive])
        let ns = raw as NSString
        guard let match = regex?.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1)) + " V"
    }
}
