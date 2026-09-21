# Pino Auto Logger v3.2 — HC24S Safe Discovery Logger

## この版の目的

HC24Sピノ／HA24S系K6Aの実車試験で，次が確認された．

- iPhone → BLE → OBDBLE/ELM327 は成立する．
- ELM327は `ATSP5`，`ATIB10`，`ATSH8111F1` を受理する．
- 明示Fast Initの `ATFI` は現在のELM327 v2.1互換機では `?` を返す．
- それでもProtocol 5の自動BUS INIT後，ECUアドレス `0x11` から有効なKWPフレームが返る．
- `3E` に対して `81 F1 11 7E 01` が返り，TesterPresentは成立する．
- `01 / 10 / 1A / 21 / 22 / 23` は実車で `7F <SID> 11`，すなわちService Not Supportedだった．

v1/v2の `ATFI → 21 00 → 61 00` 固定設計はHC24S現車に適合しないため廃止した．

## v3.2の設計

1. `ATFI`を使用しない．
2. 実車で成立した最小初期化列を使用する．
3. 最初の `3E` でELM327の自動BUS INITを発生させる．
4. `ECU 0x11 → 7E`を受けた時だけECU onlineとする．
5. KWPフレームは長さとチェックサムを検証する．
6. コマンド応答が次のコマンドへ遅延して跨る現象に対応する．
7. 全TX/RX chunk，全raw応答，全KWPフレームを日時付きCSV/TXTへ保存する．
8. 探索はread-only allowlistだけ．ECU reset，DTC消去，SecurityAccess，書込み，RoutineControl等は送らない．
9. 意味が確定していないbyteをRPM等として推測表示しない．
10. ECUが4回連続でTesterPresentへ応答しなくなればセッションを閉じ，自動再探索する．

## 自動記録の境界

現時点ではHC24S固有のRPM要求が未特定なので，「エンジン回転数 > 0」を開始条件にはできない．
v3.2はECUがonlineになった時点，すなわち通常はIG-ON〜エンジン始動時にログを開始する．
ライブデータ要求が確定した最終版ではRPM > 0を開始条件へ変更できる．

## 保存ファイル

ファイルApp:

`このiPhone内 → Pino Auto Logger → Pino OBD Logs`

に以下を保存する．

- `HC24S_DISCOVERY_yyyy-MM-dd_HH-mm-ss.csv`
- `HC24S_DISCOVERY_yyyy-MM-dd_HH-mm-ss.txt`

Documents直下には，

- `PinoProbePlan.txt`

を自動生成する．

## Custom probe plan

`PinoProbePlan.txt` は今後，HC24S固有のread-only要求が判明した際に，アプリを再ビルドせず追加試験するためのファイルである．

例:

```
R:2100
1:1A90
```

- `R:` = positive responseが確認された場合のみ走行中も反復取得
- `1:` = セッション開始時に1回だけ
- read-only allowlist外のSIDはアプリ側で拒否

## 重要

「OBDから取れる全情報」を実現するには，HC24SのSUZUKI1独自ライブデータ要求を確定させる必要がある．
HKSの適合表はHA24S/K6AをSUZUKI1として，車速，RPM，水温，点火時期，A/F補正・学習，吸気温，スロットル，インマニ圧，O2，燃料噴射時間等が取得可能であることを示す．
v3.2はそれらの存在を捏造せず，次の現車1回で通信要求を絞り込むための安全なraw収集版である．
