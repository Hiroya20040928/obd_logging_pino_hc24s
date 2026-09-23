import Foundation
import SwiftUI

@MainActor
final class AutoLoggerController: ObservableObject {
    @Published var state = "待機"
    @Published var ecuStatus = "未確認"
    @Published var adapterVoltage = "—"
    @Published var initPath = "—"
    @Published var startCommunication = "—"
    @Published var suzuki2100 = "未確認"
    @Published var suzuki2101 = "未確認"

    @Published var rpm = "—"
    @Published var speed = "—"
    @Published var coolant = "—"
    @Published var throttle = "—"
    @Published var ecuBattery = "—"
    @Published var genericMapScore = "—"

    @Published var currentCSVURL: URL?
    @Published var currentTextURL: URL?
    @Published var lastCSVURL: URL?
    @Published var lastTextURL: URL?

    @Published var autoLoggingEnabled: Bool =
        UserDefaults.standard.object(
            forKey: "autoLoggingEnabledV4"
        ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(
                autoLoggingEnabled,
                forKey: "autoLoggingEnabledV4"
            )

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

    init() {
        writer.ensureProbePlanExists()

        ble.traceSink = { [weak self] record in
            guard let self else { return }

            if self.writer.isOpen {
                self.writer.appendTransport(record)
            } else {
                self.preSessionTransport.append(record)

                if self.preSessionTransport.count > 400 {
                    self.preSessionTransport.removeFirst(
                        self.preSessionTransport.count - 400
                    )
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .elmReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startWorkerIfNeeded()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .elmDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
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

            defer {
                self.worker = nil
            }

            while !Task.isCancelled {
                if !self.autoLoggingEnabled {
                    self.state = "自動ロギングOFF"
                    try? await Task.sleep(
                        nanoseconds: 2_000_000_000
                    )
                    continue
                }

                guard self.ble.ready else {
                    self.state = "ELM327 BLE接続待ち"
                    try? await Task.sleep(
                        nanoseconds: 1_000_000_000
                    )
                    continue
                }

                do {
                    self.state = "SZ Viewer系列でELM初期化中"
                    let initResults = try await self.kwp.initializeAdapter()

                    self.state = "SUZUKI1/KWPセッション開始中"
                    let boot = await self.kwp.bootstrapSuzuki1()

                    guard boot.ecuOnline else {
                        throw HC24SError.ecuNotResponding
                    }

                    try self.beginSession()

                    for r in initResults {
                        self.writer.appendProbe(r)
                    }

                    for r in boot.probes {
                        self.writer.appendProbe(r)
                    }

                    self.initPath = boot.initPath
                    self.startCommunication =
                        boot.startCommunicationPositive ? "C1肯定応答" : "C1未確認"
                    self.suzuki2100 =
                        boot.liveCommands.contains("2100")
                        ? "61 00肯定応答"
                        : "未成立"
                    self.suzuki2101 =
                        boot.liveCommands.contains("2101")
                        ? "61 01肯定応答"
                        : "未成立"

                    self.writer.appendEvent(
                        "SUZUKI1_BOOTSTRAP",
                        note:
                            "path=\(boot.initPath), startC1=\(boot.startCommunicationPositive), live=\(boot.liveCommands.joined(separator: "|"))"
                    )

                    self.ecuStatus = "ECU 0x11 online"
                    self.consecutiveECUFailures = 0

                    let metadata = await self.kwp.readAdapterMetadata()
                    for r in metadata {
                        self.writer.appendProbe(r)

                        if r.definition.command == "ATRV" {
                            self.adapterVoltage =
                                Self.extractVoltage(r.raw) ?? "取得不能"
                        }
                    }

                    if !boot.liveCommands.isEmpty {
                        self.state =
                            "SUZUKI1 \(boot.liveCommands.joined(separator: "/")) 自動記録中"
                    } else {
                        self.state = "ECU online・21 00/21 01再試行中"
                    }

                    await self.liveLoop(
                        liveCommandsInitiallySupported: boot.liveCommands
                    )
                } catch {
                    self.finishSession(
                        reason: "CONNECT_OR_INIT_FAILED"
                    )
                    self.ecuStatus = "ECU応答未確認"
                    self.state = "5秒後に再探索"

                    try? await Task.sleep(
                        nanoseconds: 5_000_000_000
                    )
                }
            }
        }
    }

    private func liveLoop(
        liveCommandsInitiallySupported: [String]
    ) async {
        var liveCommands = liveCommandsInitiallySupported
        var voltageCounter = 0
        var retryCounter = 0

        while ble.ready
            && autoLoggingEnabled
            && !Task.isCancelled {

            let keep = await kwp.keepAlive()
            writer.appendProbe(keep)

            if kwp.isTesterPresentPositive(keep) {
                consecutiveECUFailures = 0
                ecuStatus = "ECU 0x11 online"
            } else {
                consecutiveECUFailures += 1

                if consecutiveECUFailures >= 4 {
                    ecuStatus = "ECU無応答"
                    finishSession(
                        reason: "ECU_NO_RESPONSE_4X"
                    )
                    return
                }
            }

            retryCounter += 1

            if !liveCommands.isEmpty || retryCounter >= 5 {
                retryCounter = 0

                let commandsToPoll =
                    liveCommands.isEmpty
                    ? ["2100", "2101"]
                    : liveCommands

                var newlyPositive: [String] = []

                for command in commandsToPoll {
                    let live = await kwp.readSuzukiLocalData(
                        command: command
                    )
                    writer.appendProbe(live)

                    if kwp.isSuzukiLocalPositive(
                        live,
                        command: command
                    ) {
                        newlyPositive.append(command)

                        if command == "2100" {
                            suzuki2100 = "61 00肯定応答"

                            if let snapshot =
                                SuzukiGenericLiveSnapshot.decode2100(
                                    raw: live.raw,
                                    date: live.date
                                ) {
                                writer.appendLiveSnapshot(snapshot)
                                updateSnapshot(snapshot)
                            }
                        } else if command == "2101" {
                            suzuki2101 = "61 01肯定応答"
                        }
                    } else if liveCommands.isEmpty {
                        if command == "2100" {
                            suzuki2100 =
                                live.classification.summary
                        } else if command == "2101" {
                            suzuki2101 =
                                live.classification.summary
                        }
                    }
                }

                if liveCommands.isEmpty && !newlyPositive.isEmpty {
                    liveCommands = newlyPositive
                }

                if !liveCommands.isEmpty {
                    state =
                        "SUZUKI1 \(liveCommands.joined(separator: "/")) 自動記録中"
                } else {
                    state =
                        "ECU online・21 00/21 01再試行中"
                }
            }

            voltageCounter += 1

            if voltageCounter >= 30 {
                voltageCounter = 0
                let voltage = await kwp.readVoltage()
                writer.appendProbe(voltage)

                adapterVoltage =
                    Self.extractVoltage(voltage.raw)
                    ?? adapterVoltage
            }

            try? await Task.sleep(
                nanoseconds: !liveCommands.isEmpty
                    ? 250_000_000
                    : 900_000_000
            )
        }

        finishSession(
            reason: "BLE_OR_AUTOLOG_STOP"
        )
    }

    private func updateSnapshot(
        _ s: SuzukiGenericLiveSnapshot
    ) {
        rpm = String(
            format: "%.0f rpm",
            s.rpm
        )
        speed = "\(s.speedKmh) km/h"
        coolant = "\(s.coolantC) °C"
        throttle = String(
            format: "%.1f %%",
            s.throttlePct
        )
        ecuBattery = String(
            format: "%.2f V",
            s.batteryV
        )
        genericMapScore = "\(s.sanityScore)/6"
    }

    private func beginSession() throws {
        if writer.isOpen { return }

        let urls = try writer.start()
        currentCSVURL = urls.0
        currentTextURL = urls.1

        for record in preSessionTransport {
            writer.appendTransport(record)
        }

        preSessionTransport.removeAll(
            keepingCapacity: true
        )

        writer.appendEvent(
            "ECU_ONLINE_CONFIRMED",
            note: "SUZUKI1 bootstrap"
        )
    }

    private func finishSession(
        reason: String
    ) {
        guard writer.isOpen else { return }

        writer.appendEvent(
            "SESSION_END",
            note: reason
        )

        lastCSVURL = writer.csvURL
        lastTextURL = writer.textURL

        writer.close()

        currentCSVURL = nil
        currentTextURL = nil
    }

    private static func extractVoltage(
        _ raw: String
    ) -> String? {
        let regex = try? NSRegularExpression(
            pattern: #"([0-9]{1,2}(?:\.[0-9]+)?)\s*V"#,
            options: [.caseInsensitive]
        )

        let ns = raw as NSString

        guard let match = regex?.firstMatch(
            in: raw,
            range: NSRange(
                location: 0,
                length: ns.length
            )
        ),
        match.numberOfRanges >= 2 else {
            return nil
        }

        return ns.substring(
            with: match.range(at: 1)
        ) + " V"
    }
}
