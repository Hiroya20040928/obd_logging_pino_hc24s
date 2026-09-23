# HC24S Pino Auto Logger v3.4 crash fix overlay

## Crash-log confirmed root cause

The iPhone crash report for v3.3 shows:

- Exception: EXC_BREAKPOINT / SIGTRAP
- Faulting thread: main thread
- Top relevant frame: `-[ASAccessorySession init]`
- Caller: `ELMBluetooth.init()`
- App version: 3.3 build 5
- iOS: 26.6.1

The process faults approximately 48 ms after launch. This is not a JIT failure.

v3.3 still had `private let accessorySession = ASAccessorySession()`. Stored property initialization happens before the body of `ELMBluetooth.init()`, so the v3.3 change that reordered statements inside `init()` could never protect this crash.

## v3.4 change

v3.4 completely removes AccessorySetupKit from the app runtime path and uses CoreBluetooth directly.

- no `import AccessorySetupKit`
- no `ASAccessorySession`
- no AccessorySetupKit Info.plist keys
- CoreBluetooth state restoration remains enabled
- saved `CBPeripheral.identifier` is reused
- first discovery scans directly for OBD/ELM name or advertised FFF0 service
- `bluetooth-central` background mode remains enabled

This deliberately gives up AccessorySetupKit's special force-quit relaunch path. Do not swipe-kill the app. For vehicle-entry wake-up, use the existing CarPlay/vehicle-Bluetooth Shortcuts automation as the independent trigger.

## JIT

Enable JIT is not required. The app is a native Swift/CoreBluetooth app and does not execute JIT-generated code.
