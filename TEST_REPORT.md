# v3.3 Build Fix

GitHub Actions run 35597136048で，`TripLogWriter.swift`から`@MainActor KWPProtocol`の純粋static関数`isSafeReadOnly`を同期呼出ししたため，Swiftコンパイラがactor isolation errorで停止した．v3.3では同関数を`nonisolated static`へ変更した．関数は引数文字列をbyte列へ変換してallowlist判定するだけで，共有可変状態やUI状態へアクセスしないため，nonisolated化が適切である．

ローカルSwift 6.2.1で`KWPDecoder.swift`，`KWPProtocol.swift`，`TripLogWriter.swift`をBLE stubとともにmodule compileし，actor isolation errorが解消したことを確認した．

# Test report

## 実行済み

生成環境: Swift 6.2.1 / x86_64 Linux.

`cd CoreValidation && swift test`

結果:

- 6 tests executed
- 0 failures
- 0 unexpected failures

検証項目:

- HC24S現車 `83 F1 11 7F 22 11 37` のNegative Response解析
- HC24S現車 `81 F1 11 7E 01` のTesterPresent Positive Response解析
- 現車で得た7種類のKWP frame checksum検証
- `OKELM327 v2.1` / `BUS INIT:` が混在するrawからKWP frame抽出
- スペースなしcompact frame
- checksum不正frameの排除

さらに全iOS Swiftファイルを `swiftc -frontend -parse` し，構文エラーなしを確認した．
`Info.plist` はplistとして再読込し，

- `CFBundleExecutable = $(EXECUTABLE_NAME)`
- `CFBundleShortVersionString = 3.2`

を確認した．

組込みProbeDefinitionの送信SIDを静的検査し，ECU reset，DTC消去，SecurityAccess，書込み，RoutineControl等の危険側SIDが0件であることを確認した．

追加のSuzuki K-Line既存例に基づき，読み取り専用候補 `1A8E`，`1A91`，`1A9A`，`2103` も安全探索へ追加した．これらはHC24S対応を仮定せず，正のチェックサム付き実車応答が得られた場合だけ採用する．

## GitHub Actionsで行う検証

macOS 26 + Xcode 26で，

- CoreValidation
- unsigned iPhone device build
- `CFBundleExecutable`検証
- executable存在検証
- IPA packaging

を行うWorkflowを同梱した．

## 未実施

この生成環境にはユーザーのiPhone，OBDBLE，HC24S実車がないため，v3.3の現車BLE/K-Line試験は未実施である．
したがって「v3.3がHC24S固有ライブデータを既に復号できる」とはしていない．

通信初期化は今回HC24S現車で手動成立した，

`ATSP5 / ATSH8111F1 / ATST64 / 3E -> 7E`

を基準とし，現ELM327で `?` だった `ATFI` を必須経路から除外した．


## v3.3 startup crash regression

- CoreBluetooth central is created before AccessorySetupKit activation.
- AccessorySetupKit activation is deferred to the next main run-loop turn.
- reconnect() safely returns while central is still nil.
- This removes the launch race that occurs when an already-registered OBDBLE accessory causes an immediate `.activated` callback during app initialization.
