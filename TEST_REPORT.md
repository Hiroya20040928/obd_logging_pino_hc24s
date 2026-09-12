# TEST REPORT

実施日: 2026-09-11

## 実施済み
- Swift 6.2.1/LinuxでCoreValidation packageをビルド．
- `EngineFrame.decode`の既知65-byte `61 00`フレームを検証．
- RPM=3200 rpm，speed=60 km/h，coolant=88 C，MAF=3.50 g/s，battery=14.112 Vを期待値どおり復号．
- `7F 21 12` negative responseをreject．
- `SEARCHING...`/echo混在応答を処理．
- `ATS0`でスペース無しとなったcompact hex応答を処理．
- iOS用Swift全7ファイルを`swiftc -frontend -parse`で構文検査．
- Info.plistをPython plistlibでXML/型検査．

## 未実施・物理的に実施不能
この環境にはXcode/iOS SDK，実iPhone，ユーザーのOBDBLE，HC24S実車が存在しないため，iOS実機ビルドと実BLE/K-Line通信はここでは実施できない．

従って保証範囲は，
1. KWPデータ復号・CSV設計・状態遷移ロジックの単体試験，
2. Apple公式APIに沿ったbackground CoreBluetooth / State Restoration / AccessorySetupKit設計，
3. 公開実働例に基づくSuzuki KWP init/2100経路，
までである．

最終的な実車保証は，初回インストール後にアプリ画面で「ELM327通信準備完了」→「自動ロギング中」となり，生成CSVのrpm/速度/水温が実車と一致することをもって確定する．
