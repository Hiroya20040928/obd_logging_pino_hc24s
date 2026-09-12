import Foundation
import SwiftUI

@MainActor
final class AutoLoggerController: ObservableObject {
    @Published var state = "待機"
    @Published var latestRPM: Double?
    @Published var latestSpeed: Double?
    @Published var latestCoolant: Double?
    @Published var latestBattery: Double?
    @Published var currentLogURL: URL?
    @Published var lastLogURL: URL?
    @Published var autoLoggingEnabled: Bool = UserDefaults.standard.object(forKey: "autoLoggingEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoLoggingEnabled, forKey: "autoLoggingEnabled") }
    }

    let ble = ELMBluetooth()
    private lazy var kwp = KWPProtocol(ble: ble)
    private let writer = TripLogWriter()
    private var worker: Task<Void, Never>?
    private var isLogging = false
    private var profile = ""
    private var consecutiveFailures = 0

    init() {
        NotificationCenter.default.addObserver(forName: .elmReady, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startWorkerIfNeeded() }
        }
        NotificationCenter.default.addObserver(forName: .elmDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finishTrip(reason: "BLE_DISCONNECTED") }
        }
    }

    func start() {
        ble.reconnect()
        startWorkerIfNeeded()
    }

    func setupAccessory() { ble.showAccessoryPicker() }
    func reconnect() { ble.reconnect(); startWorkerIfNeeded() }

    private func startWorkerIfNeeded() {
        guard worker == nil, autoLoggingEnabled else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.autoLoggingEnabled { self.state = "自動ロギングOFF"; try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
                guard self.ble.ready else { self.state = "ELM327接続待ち"; try? await Task.sleep(nanoseconds: 1_000_000_000); continue }

                self.state = "HC24S ECU探索中"
                do {
                    let c = try await self.kwp.connectEngine()
                    self.profile = c.profile
                    self.consecutiveFailures = 0
                    self.updateUI(c.firstFrame)

                    // Do not create a trip file on mere ignition-ON. Start only after the engine has actually rotated.
                    if (c.firstFrame.rpm ?? 0) > 0 {
                        try self.beginTripIfNeeded(firstFrame: c.firstFrame)
                    }
                    await self.liveLoop(firstFrame: c.firstFrame)
                } catch {
                    self.state = "ECU停止中・5秒後再探索"
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func liveLoop(firstFrame: EngineFrame) async {
        var frame: EngineFrame? = firstFrame
        while ble.ready && autoLoggingEnabled && !Task.isCancelled {
            if let f = frame {
                consecutiveFailures = 0
                updateUI(f)
                if !isLogging && (f.rpm ?? 0) > 0 { try? beginTripIfNeeded(firstFrame: f) }
                if isLogging { try? writer.append(frame: f, profile: profile); currentLogURL = writer.fileURL }
                state = isLogging ? "自動ロギング中" : "ECU接続済・始動待ち"
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= 4 {
                    finishTrip(reason: "ECU_NO_RESPONSE")
                    state = "ECU停止を検出"
                    return
                }
            }
            // Continuous BLE traffic keeps the KWP session alive and is compatible with iOS bluetooth-central background mode.
            try? await Task.sleep(nanoseconds: 500_000_000)
            frame = await kwp.readFrame()
        }
        finishTrip(reason: "BLE_OR_AUTOLOG_STOP")
    }

    private func beginTripIfNeeded(firstFrame: EngineFrame) throws {
        guard !isLogging else { return }
        let url = try writer.start(profile: profile)
        isLogging = true
        currentLogURL = url
    }

    private func finishTrip(reason: String) {
        guard isLogging else { return }
        try? writer.appendEvent("SESSION_END:\(reason)", profile: profile)
        lastLogURL = writer.fileURL
        writer.close()
        currentLogURL = nil
        isLogging = false
        latestRPM = nil
        latestSpeed = nil
    }

    private func updateUI(_ f: EngineFrame) {
        latestRPM = f.rpm; latestSpeed = f.speedKmh; latestCoolant = f.coolantC; latestBattery = f.batteryV
    }
}
