# Windows + GitHub Actions + AltStore 実装手順

## 1. 既存GitHubリポジトリをv3.3へ置換

GitHub Desktopで `obd_logging_pino_hc24s` を選択する．

`Repository → Show in Explorer`

を押す．

このZIP内の次の項目を，GitHubリポジトリ直下へ上書きコピーする．

- `.github`
- `CoreValidation`
- `PinoAutoLogger`
- `PinoAutoLogger.xcodeproj`
- `README_JA.md`
- `INSTALL_JA.md`
- `SOURCES.md`
- `TEST_REPORT.md`

`.git` フォルダは削除しない．
ZIPの最上位フォルダそのものをリポジトリ内へ入れて1階層深くしない．

正しい構造:

```
obd_logging_pino_hc24s/
├─ .github/
├─ CoreValidation/
├─ PinoAutoLogger/
├─ PinoAutoLogger.xcodeproj/
├─ README_JA.md
├─ INSTALL_JA.md
├─ SOURCES.md
└─ TEST_REPORT.md
```

## 2. Commit / Push

GitHub DesktopのSummary:

`HC24S v3.3 actor-isolation fix`

`Commit to main` → `Push origin`

## 3. GitHub Actions

ブラウザでリポジトリ → `Actions`

`Build Pino Auto Logger v3.3 unsigned IPA`

Pushで自動開始する．
手動なら `Run workflow`．

成功条件:

- Run protocol parser tests ✓
- Build device app without code signing ✓
- Verify app bundle ✓
- Package unsigned IPA ✓
- Upload IPA artifact ✓

Artifacts:

`PinoAutoLogger-HC24S-v3.3-unsigned-IPA`

をダウンロードする．

中身:

- `PinoAutoLogger-HC24S-v3.3-unsigned.ipa`
- SHA256ファイル

## 4. AltStoreで更新

Windows:

- AltServerを起動したまま
- iPhoneをUSB接続
- iPhoneをロック解除

iPhone:

`AltStore → My Apps → + → PinoAutoLogger-HC24S-v3.3-unsigned.ipa`

同一Bundle IDなので，まず既存Pino Auto Loggerへの更新として入れる．
更新に失敗した場合だけ既存Pino Auto Loggerを削除し，再インストールする．
削除した場合はOBDBLEの初回登録をもう一度行う．

## 5. 初回起動

1. BluetoothをON
2. Pino Auto Logger v3.3を起動
3. Bluetooth権限を許可
4. アダプターが未登録なら `OBDBLEを登録`
5. 自動ロギングをON

正常時は，

- `ELM327 BLE通信路準備完了`
- `HC24S ECU確認中`
- `ECU 0x11 online / TesterPresent OK`
- `安全read-only探索中`
- `ECU raw自動記録中`

の順に進む．

## 6. 毎回の自動起動を強化

CoreBluetooth background modeとstate restorationを実装しているが，iOSでユーザーがアプリを強制終了するとBluetoothイベントによる再起動対象から外れる．
Pino Auto LoggerをAppスイッチャーから上へ払って終了しない．

さらにショートカットAppで車両側イベントを起動トリガにする．

### CarPlayを使用する場合

`ショートカット → オートメーション → 新規 → CarPlay → 接続されたとき`

アクション:

`Appを開く → Pino Auto Logger`

自動実行を有効にする．

### CarPlayを使用しない場合

KAR7等，イグニッション連動で接続される車載Bluetoothを選び，

`ショートカット → オートメーション → Bluetooth → デバイスを選択`

アクション:

`Appを開く → Pino Auto Logger`

自動実行を有効にする．

## 7. 走行

操作不要．

実装上:

IG-ON/始動
→ 車載トリガまたはCoreBluetooth復帰
→ OBDBLE自動接続
→ ELM初期化
→ 3E
→ ECU 0x11から7E
→ 日時名でCSV/TXT作成
→ read-only探索
→ raw通信記録
→ TesterPresent維持

キーOFF
→ ECU応答消失
→ 4回連続失敗
→ CSV/TXT flush/close
→ 次回再探索待機

## 8. 次の解析に渡すファイル

走行を1回終えたら，

`ファイル → このiPhone内 → Pino Auto Logger → Pino OBD Logs`

から最新の

- `.csv`
- `.txt`

の2ファイルをChatGPTへ渡す．

この2つにはKWPチェックサム付きframeと全raw通信が残る．
意味が未確定な値は削除されない．
