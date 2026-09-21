import Foundation
import CoreBluetooth
import AccessorySetupKit
import UIKit

struct TransportRecord: Sendable {
    let date: Date
    let direction: String
    let text: String
}

@MainActor
final class ELMBluetooth: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "FFF0")
    static let notifyUUID = CBUUID(string: "FFF1")
    static let writeUUID = CBUUID(string: "FFF2")
    private static let restoreID = "jp.local.pinoautologger.central.v3"
    private static let savedPeripheralKey = "PinoAutoLogger.peripheralUUID"

    @Published private(set) var bluetoothStatus = "初期化中"
    @Published private(set) var accessoryName = "未登録"
    @Published private(set) var connected = false
    @Published private(set) var ready = false

    var traceSink: ((TransportRecord) -> Void)?

    private let accessorySession = ASAccessorySession()
    private var pendingAccessory: ASAccessory?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var rxBuffer = ""
    private var idleBuffer = ""
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var pendingToken: UUID?
    private var settleTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var accessoryKitActive = false
    private var fallbackScanning = false

    override init() {
        super.init()
        activateAccessorySession()
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    func showAccessoryPicker() {
        if accessoryKitActive {
            let d = ASDiscoveryDescriptor()
            d.bluetoothServiceUUID = Self.serviceUUID
            d.bluetoothNameSubstring = "OBD"
            let image = UIImage(systemName: "car.fill") ?? UIImage()
            let item = ASPickerDisplayItem(name: "OBDBLE / ELM327", productImage: image, descriptor: d)
            accessorySession.showPicker(for: [item]) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.bluetoothStatus = "登録UI失敗・BLE直接検索へ切替: \(error.localizedDescription)"
                    self.startFallbackScan()
                }
            }
        } else {
            startFallbackScan()
        }
    }

    func reconnect() {
        guard central.state == .poweredOn else { return }
        if let idString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
           let id = UUID(uuidString: idString),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            attachAndConnect(p)
        } else if let a = accessorySession.accessories.first(where: { $0.bluetoothIdentifier != nil }),
                  let id = a.bluetoothIdentifier,
                  let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            UserDefaults.standard.set(id.uuidString, forKey: Self.savedPeripheralKey)
            accessoryName = a.displayName
            attachAndConnect(p)
        } else {
            startFallbackScan()
        }
    }

    func send(_ command: String, timeout: TimeInterval = 4.0) async throws -> String {
        guard let p = peripheral, p.state == .connected, let w = writeCharacteristic else {
            throw ELMError.notConnected
        }
        if pendingContinuation != nil { throw ELMError.commandBusy }

        let token = UUID()
        pendingToken = token

        // 前コマンドの遅延KWPフレームが到着していた場合も次の応答に含め，
        // SID/チェックサムで上位層が正しく相関できるようにする．
        rxBuffer = idleBuffer
        idleBuffer = ""

        traceSink?(TransportRecord(date: Date(), direction: "TX", text: command))

        let payload = Data((command.trimmingCharacters(in: .whitespacesAndNewlines) + "\r").utf8)

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation

            let type: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
            p.writeValue(payload, for: w, type: type)

            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishPending(token: token)
            }
        }
    }

    private func schedulePromptSettle(token: UUID) {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            // Car Scanner実機でコマンド間に遅延応答が跨ったため，
            // prompt直後に即returnせず300msの静穏時間を取る．
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.finishPending(token: token)
        }
    }

    private func finishPending(token: UUID) {
        guard pendingToken == token, let c = pendingContinuation else { return }
        settleTask?.cancel()
        timeoutTask?.cancel()
        pendingContinuation = nil
        pendingToken = nil
        let out = rxBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        rxBuffer = ""
        c.resume(returning: out)
    }

    private func activateAccessorySession() {
        accessorySession.activate(on: .main) { [weak self] event in
            guard let self else { return }
            switch event.eventType {
            case .activated:
                self.accessoryKitActive = true
                if let a = self.accessorySession.accessories.first(where: { $0.bluetoothIdentifier != nil }) {
                    self.accessoryName = a.displayName
                    if let id = a.bluetoothIdentifier {
                        UserDefaults.standard.set(id.uuidString, forKey: Self.savedPeripheralKey)
                    }
                    self.reconnect()
                }
            case .accessoryAdded:
                self.pendingAccessory = event.accessory
            case .pickerDidDismiss:
                if let a = self.pendingAccessory {
                    self.pendingAccessory = nil
                    self.accessoryName = a.displayName
                    if let id = a.bluetoothIdentifier {
                        UserDefaults.standard.set(id.uuidString, forKey: Self.savedPeripheralKey)
                    }
                    self.reconnect()
                }
            case .accessoryChanged:
                if let a = event.accessory { self.accessoryName = a.displayName }
            case .accessoryRemoved:
                UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
                self.accessoryName = "未登録"
            case .invalidated:
                self.accessoryKitActive = false
                self.bluetoothStatus = "AccessorySetupKit無効・BLE直接検索へ切替"
                self.startFallbackScan()
            default:
                break
            }
        }
    }

    private func startFallbackScan() {
        guard central != nil, central.state == .poweredOn, !fallbackScanning else { return }
        fallbackScanning = true
        bluetoothStatus = "OBDBLEをBLE直接検索中"
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func stopFallbackScan() {
        guard fallbackScanning else { return }
        central.stopScan()
        fallbackScanning = false
    }

    private func attachAndConnect(_ p: CBPeripheral) {
        if peripheral?.identifier == p.identifier && (p.state == .connected || p.state == .connecting) { return }
        peripheral = p
        p.delegate = self
        ready = false
        bluetoothStatus = "OBDBLEへ接続待機"
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func chooseCharacteristics() {
        guard let p = peripheral else { return }
        var notify: CBCharacteristic?
        var write: CBCharacteristic?

        for service in p.services ?? [] {
            for c in service.characteristics ?? [] {
                if c.uuid == Self.notifyUUID && (c.properties.contains(.notify) || c.properties.contains(.indicate)) {
                    notify = c
                }
                if c.uuid == Self.writeUUID && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) {
                    write = c
                }
                // 一部クローンはFFF1一つでnotify/writeを兼用する．
                if c.uuid == Self.notifyUUID && write == nil &&
                    (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) {
                    write = c
                }
            }
        }

        notifyCharacteristic = notify
        writeCharacteristic = write

        guard let n = notify, write != nil else {
            bluetoothStatus = notify == nil ? "FFF1 Notifyが見つかりません" : "Write characteristicが見つかりません"
            return
        }

        p.setNotifyValue(true, for: n)
    }
}

enum ELMError: Error {
    case notConnected
    case commandBusy
}

extension ELMBluetooth: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth ON"
            reconnect()
        case .poweredOff:
            bluetoothStatus = "Bluetooth OFF"
        case .unauthorized:
            bluetoothStatus = "Bluetooth権限なし"
        default:
            bluetoothStatus = "Bluetooth待機"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p
            p.delegate = self
            accessoryName = p.name ?? "OBDBLE"
            if p.state == .connected {
                connected = true
                p.discoverServices(nil)
            } else {
                central.connect(p, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        if advertisedName.isEmpty ||
            advertisedName.localizedCaseInsensitiveContains("OBD") ||
            advertisedName.localizedCaseInsensitiveContains("ELM") {
            stopFallbackScan()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
            accessoryName = advertisedName.isEmpty ? "OBD BLE" : advertisedName
            attachAndConnect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stopFallbackScan()
        connected = true
        ready = false
        bluetoothStatus = "OBDBLE接続済"
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connected = false
        ready = false
        bluetoothStatus = "接続失敗・再待機"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false
        ready = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        bluetoothStatus = "切断・自動再接続待機"

        if let c = pendingContinuation {
            pendingContinuation = nil
            pendingToken = nil
            settleTask?.cancel()
            timeoutTask?.cancel()
            c.resume(throwing: ELMError.notConnected)
        }

        NotificationCenter.default.post(name: .elmDidDisconnect, object: nil)
        central.connect(peripheral, options: nil)
    }
}

extension ELMBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            bluetoothStatus = "サービス探索失敗: \(error.localizedDescription)"
            return
        }
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            bluetoothStatus = "Characteristic探索失敗: \(error.localizedDescription)"
            return
        }
        chooseCharacteristics()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            bluetoothStatus = "Notify有効化失敗: \(error.localizedDescription)"
            return
        }
        if characteristic.uuid == Self.notifyUUID && characteristic.isNotifying && writeCharacteristic != nil {
            ready = true
            bluetoothStatus = "ELM327 BLE通信路準備完了"
            NotificationCenter.default.post(name: .elmReady, object: nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let chunk = String(decoding: data, as: UTF8.self)
        traceSink?(TransportRecord(date: Date(), direction: "RX_CHUNK", text: chunk))

        if pendingContinuation != nil {
            rxBuffer += chunk
            if rxBuffer.contains(">"), let token = pendingToken {
                schedulePromptSettle(token: token)
            }
        } else {
            idleBuffer += chunk
            if idleBuffer.count > 8192 {
                idleBuffer = String(idleBuffer.suffix(8192))
            }
        }
    }
}

extension Notification.Name {
    static let elmReady = Notification.Name("PinoAutoLogger.elmReady")
    static let elmDidDisconnect = Notification.Name("PinoAutoLogger.elmDidDisconnect")
}
