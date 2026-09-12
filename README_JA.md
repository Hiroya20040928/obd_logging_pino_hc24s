
## Macを持っていない場合

Macは不要です．`NO_MAC_SETUP_JA.md`の手順で，GitHub ActionsのmacOS 26 runnerにXcodeビルドを実行させ，Windows＋AltStore ClassicからiPhoneへ導入できます．また，AccessorySetupKitが使えない署名環境に備え，FFF0 BLEサービスを直接探索するfallbackも実装しています．

# Pino Auto Logger for iPhone（HC24S / HA24S KWP）

## 目的
- iPhoneからBLE ELM327（OBDBLE）へ自動接続する．
- Suzuki系KWP2000 Fast Init，ECU address 0x11，`21 00`を使用する．
- エンジン回転を検出した時点で `HC24S_YYYY-MM-DD_HH-mm-ss.csv` を自動作成する．
- 走行中は0.5秒周期で `3E` + `2100` を取得し，既知項目と61 00応答の全生byteを保存する．
- ECUが4回連続無応答，またはBLE切断で自動終了・flush・closeする．
- 次回は再びECUを探索し，自動で新しいファイルを作る．

## 重要な設計判断
OBD DLC pin 16は通常バッテリー常時電源であり，安価なELM327はキーOFFでもBLE自体が切断しない場合がある．そのため「BLE切断だけ」をエンジンOFF判定には使わない．ECUの`2100`無応答も終了条件にする．逆に信号待ちのエンスト等でRPM=0になってもECU応答が続く限りファイルは閉じない．

## 初回インストール
1. MacにXcode 26以降をインストールする．
2. `PinoAutoLogger.xcodeproj`を開く．
3. TARGETS → PinoAutoLogger → Signing & Capabilities → Teamで自分のApple ID/Developer Teamを選ぶ．
4. Bundle Identifierが衝突する場合は `jp.local.PinoAutoLogger.<任意文字列>` に変更する．
5. iPhoneをMacへ接続し，実機をRun先に選択する．
6. Run（▶）でインストールする．
7. 初回だけアプリの「OBDBLEを登録」を押し，AppleのAccessorySetupKit画面でOBDBLEを選ぶ．
8. 「自動ロギング」をONのままにする．

## 実運用
- アプリを一度起動してOBDBLEを登録しておけば，CoreBluetooth State Restorationと`bluetooth-central` background modeにより再接続を待機する．
- エンジン始動 → KWP `61 00`受信かつRPM>0 → 自動で新規CSV開始．
- キーOFF → ECU `2100`無応答が4回連続 → CSVを閉じる．BLE自体が落ちた場合は即時終了する．
- ログは「ファイル」App → このiPhone内 → Pino Auto Logger → Pino OBD Logs に保存される．

## CSVに保存する内容
時刻，Unix時刻，RPM，車速，水温，吸気温，スロットル，TPS電圧，エンジン負荷，MAP，MAF，点火時期，O2，STFT/LTFT，噴射パルス，気圧，IAC，目標アイドル，バッテリー電圧，MAFからの推定燃料流量・瞬間/区間燃費，`raw_payload_hex`，`raw_response`，および`b00`〜`b64`の全65 byte．

## 「OBDから取れる全て」の意味
公開根拠があるHC24S/旧Suzuki系の実走行用データブロックは`21 00`→`61 00 + 65 bytes`である．この65 bytesは1 byteも捨てずCSVへ保存する．未確認のメーカー固有local IDやSRS/ABSのroutine-control等を総当たりする実装は，データ意味が不明で診断セッションへ副作用を入れるため自動実行しない．読み取り範囲を増やす場合は現車で正応答を確認したread-only IDだけ追加する．

## iOS側の制約
- Bluetoothを「設定」アプリからOFFにすると自動再接続できない．
- 再起動直後は一度iPhoneをロック解除するまでBluetooth State Restorationによる再起動は行われない．
- iOS 26ではユーザーForce Quit後のBluetooth relaunchはAccessorySetupKitでセットアップしたアクセサリが前提で，本アプリはその方式を実装している．
- 無料Apple IDでXcodeから直接入れた開発Appは署名期限が短い．常用するなら有料Developer Team，TestFlight/App Store配布，または定期再署名が必要．

## 毎回確実に起動させるためのトリガ（重要）
安価なELM327はDLC pin 16の常時電源でキーOFF後もBLE接続が残る場合がある．その場合，「次のキーON」はBluetooth接続イベントではないため，iOSが完全にsuspendした後にOBDだけを見て100%起動させることはできない．

したがって実運用は次のどちらかを必ず併用する．
1. CarPlay使用車: 「ショートカット」→「オートメーション」→「CarPlay」→「接続されたとき」→「Appを開く」→ Pino Auto Logger →「すぐに実行」．
2. CarPlayを使わない場合: 車載オーディオのBluetooth接続をトリガに同じ「Appを開く」を設定する．

これにより，イグニッションでヘッドユニットが起動するたびアプリも起動し，その後はBLE ELM327→KWP ECUへ自動接続する．CoreBluetooth State Restorationは二重化として残る．
