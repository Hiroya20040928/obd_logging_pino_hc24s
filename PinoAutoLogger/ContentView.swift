import SwiftUI

struct ContentView: View {
    @EnvironmentObject var controller: AutoLoggerController

    var body: some View {
        NavigationStack {
            Form {
                Section("状態") {
                    LabeledContent(
                        "自動ロガー",
                        value: controller.state
                    )
                    LabeledContent(
                        "Bluetooth",
                        value: controller.ble.bluetoothStatus
                    )
                    LabeledContent(
                        "アダプター",
                        value: controller.ble.accessoryName
                    )
                    LabeledContent(
                        "ECU",
                        value: controller.ecuStatus
                    )
                    Toggle(
                        "自動ロギング",
                        isOn: $controller.autoLoggingEnabled
                    )
                }

                Section("SUZUKI1セッション") {
                    LabeledContent(
                        "初期化経路",
                        value: controller.initPath
                    )
                    LabeledContent(
                        "StartCommunication",
                        value: controller.startCommunication
                    )
                    LabeledContent(
                        "21 00",
                        value: controller.suzuki2100
                    )
                    LabeledContent(
                        "21 01",
                        value: controller.suzuki2101
                    )
                    LabeledContent(
                        "ELM表示電圧",
                        value: controller.adapterVoltage
                    )
                }

                Section("SZ Viewer汎用map候補値") {
                    LabeledContent(
                        "RPM",
                        value: controller.rpm
                    )
                    LabeledContent(
                        "速度",
                        value: controller.speed
                    )
                    LabeledContent(
                        "水温",
                        value: controller.coolant
                    )
                    LabeledContent(
                        "スロットル",
                        value: controller.throttle
                    )
                    LabeledContent(
                        "ECU電圧候補",
                        value: controller.ecuBattery
                    )
                    LabeledContent(
                        "妥当範囲一致",
                        value: controller.genericMapScore
                    )

                    Text(
                        "この欄はSZ Viewer由来のEngine_KWP_00_Local系offsetを21 00応答だけに適用した未検証mapです．HC24Sでの意味確定前はraw CSV/TXTを正本として扱います．"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("接続") {
                    Button("OBDBLEを検索・登録") {
                        controller.setupAccessory()
                    }

                    Button("再接続") {
                        controller.reconnect()
                    }

                    Text(
                        "v4.1は標準OBD探索を停止し，SZ Viewer由来のSUZUKI1/KWP初期化へ切替えています．ATFIが未実装のELM cloneではStartCommunication 0x81を最初の車両要求にしてELMの自動fast-initへ切替えます．"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("ログ") {
                    Text(
                        "保存先：ファイル App → このiPhone内 → Pino Auto Logger → Pino OBD Logs"
                    )
                    .font(.footnote)

                    if let csv =
                        controller.lastCSVURL
                        ?? controller.currentCSVURL {
                        ShareLink(item: csv) {
                            Label(
                                "CSVを共有",
                                systemImage:
                                    "square.and.arrow.up"
                            )
                        }

                        Text(csv.lastPathComponent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    if let txt =
                        controller.lastTextURL
                        ?? controller.currentTextURL {
                        ShareLink(item: txt) {
                            Label(
                                "raw TXTを共有",
                                systemImage:
                                    "square.and.arrow.up"
                            )
                        }

                        Text(txt.lastPathComponent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("安全制約") {
                    Text(
                        "送信する車両サービスはStartCommunication 0x81，TesterPresent 0x3E，ReadDataByLocalIdentifier 0x21/00だけです．DTC消去，ECU Reset，SecurityAccess，Write，RoutineControl，Actuator Controlは実装していません．"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(
                "Pino Auto Logger v4.1"
            )
        }
    }
}
