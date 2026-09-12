# MacなしでiPhoneへ導入する手順（Windows＋GitHub Actions＋AltStore Classic）

このプロジェクトは，ローカルMacなしで導入できる．ビルドはGitHub ActionsのmacOS 26ランナーに行わせ，WindowsのAltServer / iPhoneのAltStore Classicで署名・インストールする．

## 0．必要なもの

- Windows 10/11 PC
- iPhone（iOS 26）
- Apple ID
- GitHubアカウント
- このプロジェクト一式
- 車載のBLE ELM327（現在のOBDBLE）

## 1．GitHubでIPAをビルド

1. GitHubで空のPrivate repositoryを作る．例：`pino-hc24s-autologger`．
2. このフォルダの中身をrepoのルートへアップロードする．`.github/workflows/build-unsigned-ipa.yml`を必ず含める．
3. GitHubの`Actions`タブを開く．
4. `Build unsigned iPhone IPA`を選択し，`Run workflow`を押す．
5. 完了後，実行結果の`Artifacts`から`PinoAutoLogger-HC24S-unsigned-IPA`をダウンロードする．
6. 中の`PinoAutoLogger-HC24S-unsigned.ipa`がiPhoneへ入れる元ファイルである．

GitHub側はmacOS 26 hosted runnerとXcode 26を使うので，手元にMac/Xcodeは不要．コード署名はここでは行わない．

## 2．WindowsへAltStore Classicを導入

1. Apple配布版のiTunesとiCloudをWindowsへ入れる（Microsoft Store版ではなくApple公式配布版を優先）．
2. AltServer for Windowsを入れる．
3. AltServerを「管理者として実行」する．
4. iPhoneをUSBでWindowsへ接続し，「このコンピュータを信頼」を許可する．
5. iTunesで「Wi-Fi経由でこのiPhoneと同期」をONにする．
6. AltServerのタスクトレイアイコン → `Install AltStore` → 自分のiPhoneを選ぶ．
7. Apple IDで認証する．
8. iPhoneで「設定 → プライバシーとセキュリティ → デベロッパモード」をONにする．
9. 必要なら「設定 → 一般 → VPNとデバイス管理」で自分のApple IDの開発元を信頼する．

## 3．Pino Auto Loggerを入れる

推奨：AltStore Classicを使う．

1. GitHub Actionsから取得したIPAをiCloud Drive等でiPhoneの「ファイル」へ置く．
2. iPhoneでAltStoreを開く．
3. `My Apps`の`+`からIPAを選ぶ（またはファイル共有からAltStoreで開く）．
4. Windows側のAltServerを起動したまま，同じLAN上でインストールを完了する．

無料Apple IDではアプリ署名が7日で失効する．AltStoreはWindows上のAltServerと同じLANにいる間にバックグラウンド更新を試みるため，Windows起動時にAltServerを自動起動しておく．7日を跨いで更新できなかった場合，アプリは開けなくなる．

## 4．初回だけiPhone側で行う設定

1. `Pino Auto Logger`を開く．
2. Bluetooth利用を許可する．
3. 「OBDBLEを登録」を押す．AccessorySetupKitが利用できればAppleの登録UIを使用する．利用できない署名環境では，本アプリはFFF0サービスを持つOBD BLEを直接検索するfallbackへ自動移行する．
4. OBDBLEへの接続を確認する．
5. エンジンを始動し，画面が`ELM327通信準備完了` → ECU接続 → ロギングへ遷移することを確認する．

## 5．日常運用

- アプリをAppスイッチャーから上へ払って強制終了しない．
- iOSのBluetoothを常時ONにする．
- バックグラウンド更新を妨げるため，低電力モード常用は避ける．
- エンジン始動後，保存済みCBPeripheralへ再接続する．
- ECUから`61 00`が返りRPM>0になった時点で日付時刻名のCSVを新規作成する．
- エンジン停止後，ECU応答消失またはBLE切断を検出するとCSVを閉じる．
- ログは「ファイル → このiPhone内 → Pino Auto Logger → Pino OBD Logs」へ保存する．

## 6．「毎回完全自動」の実運用上の条件

CoreBluetoothの`bluetooth-central` background modeを宣言しているので，通常のbackground/suspended状態からBLEイベントで復帰できる．ただし，ユーザーがアプリを強制終了した後の再起動挙動はiOS管理下にあり，サイドロード方式では100%保証しない．

確実性を上げるには，CarPlay接続をトリガとするショートカット・オートメーションで`Pino Auto Logger`を開く設定を併用する．これにより乗車時にアプリを前面復帰させ，その後はOBDBLE再接続とロギングをアプリが自動実行する．

## 7．無料運用の最大の制約

Macの有無ではなく，無料署名の7日制限が最大の制約．日常運用で7日更新が許容できない場合は，Apple Developer Programの有料アカウント＋正式な配布/署名方式へ移す．その場合もGitHub Actionsでビルドできるため，Mac購入は不要．
