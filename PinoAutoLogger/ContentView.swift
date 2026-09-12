import SwiftUI

struct ContentView: View {
    @EnvironmentObject var controller: AutoLoggerController

    var body: some View {
        NavigationStack {
            Form {
                Section("状態") {
                    LabeledContent("自動ロガー", value: controller.state)
                    LabeledContent("Bluetooth", value: controller.ble.bluetoothStatus)
                    LabeledContent("アダプター", value: controller.ble.accessoryName)
                    Toggle("自動ロギング", isOn: $controller.autoLoggingEnabled)
                }
                Section("現在値") {
                    LabeledContent("RPM", value: value(controller.latestRPM, "rpm"))
                    LabeledContent("速度", value: value(controller.latestSpeed, "km/h"))
                    LabeledContent("水温", value: value(controller.latestCoolant, "℃"))
                    LabeledContent("電圧", value: value(controller.latestBattery, "V"))
                }
                Section("初回設定") {
                    Button("OBDBLEを登録") { controller.setupAccessory() }
                    Button("再接続") { controller.reconnect() }
                    Text("初回だけAccessorySetupKitでOBDBLEを登録します．以後は保存したBluetooth識別子へ自動再接続します．")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("ログ") {
                    Text("保存先：ファイル App → このiPhone内 → Pino Auto Logger → Pino OBD Logs")
                        .font(.footnote)
                    if let url = controller.lastLogURL ?? controller.currentLogURL {
                        ShareLink(item: url) { Label("最新CSVを共有", systemImage: "square.and.arrow.up") }
                        Text(url.lastPathComponent).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Pino Auto Logger")
        }
    }

    private func value(_ x: Double?, _ unit: String) -> String {
        guard let x else { return "—" }
        return String(format: "%.1f %@", x, unit)
    }
}
