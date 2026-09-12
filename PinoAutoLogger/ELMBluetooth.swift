import Foundation
import CoreBluetooth
import AccessorySetupKit
import UIKit

@MainActor
final class ELMBluetooth: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "FFF0")
    static let notifyUUID = CBUUID(string: "FFF1")
    static let writeUUID = CBUUID(string: "FFF2")
    private static let restoreID = "jp.local.pinoautologger.central"
    private static let savedPeripheralKey = "PinoAutoLogger.peripheralUUID"

    @Published private(set) var bluetoothStatus = "初期化中"
    @Published private(set) var accessoryName = "未登録"
    @Published private(set) var connected = false
    @Published private(set) var ready = false

    private let accessorySession = ASAccessorySession()
    private var pendingAccessory: ASAccessory?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var rxBuffer = ""
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var pendingToken: UUID?
    private var starting = false
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
            bluetoothStatus = "OBDBLEを直接検索中"
            startFallbackScan()
        }
    }

    private func startFallbackScan() {
        guard central != nil, central.state == .poweredOn, !fallbackScanning else { return }
        fallbackScanning = true
        bluetoothStatus = "OBDBLEをBLE直接検索中"
        // Background scanでも成立するよう，既知のFFF0サービスに限定する．
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func stopFallbackScan() {
        guard fallbackScanning else { return }
        central.stopScan()
        fallbackScanning = false
    }

    func send(_ command: String, timeout: TimeInterval = 4.0) async throws -> String {
        guard let p = peripheral, p.state == .connected, let w = writeCharacteristic else {
            throw ELMError.notConnected
        }
        if pendingContinuation != nil { throw ELMError.commandBusy }
        rxBuffer = ""
        let token = UUID(); pendingToken = token
        let payload = Data((command.trimmingCharacters(in: .whitespacesAndNewlines) + "\r").utf8)
        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
            let type: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
            p.writeValue(payload, for: w, type: type)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.pendingToken == token, let c = self.pendingContinuation else { return }
                self.pendingContinuation = nil; self.pendingToken = nil
                c.resume(returning: self.rxBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
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
            default: break
            }
        }
    }

    private func attachAndConnect(_ p: CBPeripheral) {
        if peripheral?.identifier == p.identifier && (p.state == .connected || p.state == .connecting) { return }
        peripheral = p; p.delegate = self
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
                if c.uuid == Self.notifyUUID && (c.properties.contains(.notify) || c.properties.contains(.indicate)) { notify = c }
                if c.uuid == Self.writeUUID && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) { write = c }
                if c.uuid == Self.notifyUUID && write == nil && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) { write = c }
            }
        }
        notifyCharacteristic = notify
        writeCharacteristic = write
        if let n = notify {
            p.setNotifyValue(true, for: n)
            if write != nil {
                ready = true
                bluetoothStatus = "ELM327通信準備完了"
            }
        } else {
            bluetoothStatus = "FFF1 Notifyが見つかりません"
        }
    }
}

enum ELMError: Error { case notConnected, commandBusy }

extension ELMBluetooth: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothStatus = "Bluetooth ON"; reconnect()
        case .poweredOff: bluetoothStatus = "Bluetooth OFF"
        case .unauthorized: bluetoothStatus = "Bluetooth権限なし"
        default: bluetoothStatus = "Bluetooth待機"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p; p.delegate = self
            accessoryName = p.name ?? "OBDBLE"
            if p.state == .connected {
                connected = true
                p.discoverServices(nil)
            } else {
                central.connect(p, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        // FFF0サービスで絞っているため，名称が空のクローンでも候補とする．
        if advertisedName.isEmpty || advertisedName.localizedCaseInsensitiveContains("OBD") || advertisedName.localizedCaseInsensitiveContains("ELM") {
            stopFallbackScan()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
            accessoryName = advertisedName.isEmpty ? "OBD BLE" : advertisedName
            attachAndConnect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stopFallbackScan()
        connected = true; ready = false; bluetoothStatus = "OBDBLE接続済"
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connected = false; ready = false; bluetoothStatus = "接続失敗・再待機"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false; ready = false; writeCharacteristic = nil; notifyCharacteristic = nil
        bluetoothStatus = "切断・自動再接続待機"
        if let c = pendingContinuation {
            pendingContinuation = nil; pendingToken = nil
            c.resume(throwing: ELMError.notConnected)
        }
        NotificationCenter.default.post(name: .elmDidDisconnect, object: nil)
        central.connect(peripheral, options: nil)
    }
}

extension ELMBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { bluetoothStatus = "サービス探索失敗: \(error.localizedDescription)"; return }
        for s in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { bluetoothStatus = "Characteristic探索失敗: \(error.localizedDescription)"; return }
        chooseCharacteristics()
        if ready { NotificationCenter.default.post(name: .elmReady, object: nil) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        rxBuffer += String(decoding: data, as: UTF8.self)
        guard let range = rxBuffer.range(of: ">"), let c = pendingContinuation else { return }
        let response = String(rxBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        pendingContinuation = nil; pendingToken = nil
        c.resume(returning: response)
    }
}

extension Notification.Name {
    static let elmReady = Notification.Name("PinoAutoLogger.elmReady")
    static let elmDidDisconnect = Notification.Name("PinoAutoLogger.elmDidDisconnect")
}
