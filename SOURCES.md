# Sources / design basis

1. 実車HC24Sで確認したKWP応答
   - 83 F1 11 7F 01 11 16
   - 83 F1 11 7F 10 11 25
   - 83 F1 11 7F 1A 11 2F
   - 83 F1 11 7F 21 11 36
   - 83 F1 11 7F 22 11 37
   - 83 F1 11 7F 23 11 38
   - 81 F1 11 7E 01
   これらは全て末尾checksumが一致した．

2. SZ Viewer official
   https://malykh.com/soft/sz-viewer/
   Suzuki J1962 pin 7 K-Line，fast init / 5-baud initをサポート．

3. HKS OB-LINK application list
   https://www.hks-power.co.jp/product_search/product/735/maker/7
   HA24S/K6A(NA), 04/09-09/12, communication type SUZUKI1.
   Speed, RPM, coolant, ignition timing, A/F correction/learning, intake air temperature,
   throttle, intake manifold pressure, O2 voltage, fuel injection time等の取得可否を掲載．

4. Apple Core Bluetooth background processing / state restoration
   https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html

5. Apple TN3115 Bluetooth State Restoration app relaunch rules
   https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules

6. Apple Shortcuts automation
   https://support.apple.com/guide/shortcuts/add-automations-apdfbdbd7123/ios

7. KWP service reference implementation
   https://github.com/secdev/scapy/blob/master/scapy/contrib/automotive/kwp.py

8. Suzuki Cultus KWP reverse-engineering example
   https://github.com/talhabalaj/suzuki-cultus-obd
   21 00 is a valid example for that ECU, but HC24S実車ではService 21自体がNRC11のため流用しない．

## Additional Suzuki K-Line discovery precedent

- 4PDA ELM327 Suzuki KWP discussions show `ATSP5`, `ATSH8111F1`, `3E`, then read-only identification probes `1A8E` / `1A9A` on ECU address 0x11.
- Arduino Suzuki/K-Line reverse-engineering discussions show read-only `1A9A` ECU identification and `2108` ReadDataByLocalIdentifier patterns on related Suzuki K-Line systems.

These are treated only as discovery candidates. HC24S support is not assumed until the actual car returns a positive checksummed KWP response.
