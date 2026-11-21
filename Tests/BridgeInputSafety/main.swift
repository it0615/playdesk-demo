import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
// No Android tools, devices, sockets, profiles or actual Process execution.
let bridge = AndroidBridge(tools: ToolPaths(sdk: nil, adb: nil, emulator: nil, scrcpy: nil))
for package in ["", "-n", "com.example;id", "com.example\nother", "com.example space", "com.example/Activity", "com..example", ".example", "com.example.", "com.1example", "com.exämple"] {
    var rejectedBeforeTool = false
    do { _ = try bridge.launch(package: package, serial: "emulator-5554") }
    catch BridgeError.failed(let message) { rejectedBeforeTool = message.contains("패키지") }
    catch {}
    check(rejectedBeforeTool, "reject invalid package \(String(reflecting: package)) before adb")
}
for package in ["com.example", "com.example_game.Game2", "android"] {
    var reachedTool = false
    do { _ = try bridge.launch(package: package, serial: "emulator-5554") }
    catch BridgeError.missing { reachedTool = true }
    catch {}
    check(reachedTool, "valid package reaches adb guard: \(package)")
}
exit(failures == 0 ? 0 : 1)
