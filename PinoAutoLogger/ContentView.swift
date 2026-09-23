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
                    LabeledContent("ECU", value: controller.ecuStatus)
                    Toggle("自動ロギング", isOn: $controller.autoLoggingEnabled)
                }

                Section("診断") {
                    LabeledContent("ELM電源電圧", value: controller.adapterVoltage)
                    LabeledContent("Positive probe", value: "\(controller.positiveProbeCount)")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最終KWPフレーム")
                        Text(controller.lastKWPFrame)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("初回設定") {
                    Button("OBDBLEを登録") {
                        controller.setupAccessory()
                    }
                    Button("再接続") {
                        controller.reconnect()
                    }
                    Text("実車で確認済みのProtocol 5 / ECU 0x11 / TesterPresentを基準に接続します．ATFIは使用しません．")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("ログ") {
                    Text("保存先：ファイル App → このiPhone内 → Pino Auto Logger → Pino OBD Logs")
                        .font(.footnote)

                    if let csv = controller.lastCSVURL ?? controller.currentCSVURL {
                        ShareLink(item: csv) {
                            Label("CSVを共有", systemImage: "square.and.arrow.up")
                        }
                        Text(csv.lastPathComponent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    if let txt = controller.lastTextURL ?? controller.currentTextURL {
                        ShareLink(item: txt) {
                            Label("raw TXTを共有", systemImage: "square.and.arrow.up")
                        }
                        Text(txt.lastPathComponent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("重要") {
                    Text("v3はHC24S固有ライブデータ要求を特定するための安全探索版です．書込み，ECU reset，DTC消去，SecurityAccess，RoutineControlは送信しません．意味未確定のraw byteをRPM等として推測表示しません．")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pino Auto Logger v3")
        }
    }
}
