# 根拠資料

1. Apple Core Bluetooth background execution / state restoration
   - https://developer.apple.com/documentation/corebluetooth
   - https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules
   - https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
2. Apple AccessorySetupKit
   - https://developer.apple.com/documentation/accessorysetupkit
   - https://developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories
   - https://developer.apple.com/documentation/bundleresources/information-property-list/nsaccessorysetupsupports
3. BLE ELM327 UART layout
   - OBDLink CX: FFF0 service / FFF1 notify / FFF2 write
   - https://support.obdlink.com/support/solutions/articles/43000746707-obdlink-cx-adapter-notes
4. Suzuki KWP live-data implementation
   - https://github.com/talhabalaj/suzuki-cultus-obd
   - Engine ECU target 0x11, ATSH 81 11 F1, service 21 local-ID 00, positive response 61 00, 65-byte block
5. ELM327 low-power / ignition-monitor limitation
   - https://www.scantool.net/scantool/downloads/103/elm327dsh.pdf
   - DLCには通常switched ignition電源がなく，Pin 16は常時電源系であるため，キーOFFとBLE切断を同一視しない．
