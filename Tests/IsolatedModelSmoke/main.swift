import AppKit
import SwiftUI

@main
struct IsolatedModelSmoke {
    @MainActor static func main() async throws {
        // Separate-process restart verification uses only the parent's synthetic store.
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--verify-restart" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            let domain = CommandLine.arguments[3]
            guard root.lastPathComponent.hasPrefix("playdesk-smoke-"),
                  root.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL,
                  domain.hasPrefix("PlayDesk.IsolatedSmoke."),
                  let defaults = UserDefaults(suiteName: domain) else { fatalError("Not an isolated test store") }
            let model = LauncherModel(
                bridge: AndroidBridge(tools: ToolPaths(sdk: nil, adb: nil, emulator: nil, scrcpy: nil)),
                store: ProfileStore(url: root.appendingPathComponent("profiles.json")), defaults: defaults)
            model.selectedPackage = "example.synthetic"
            guard model.selectedName == "Edited synthetic", model.selectedAVD == "Other_Synthetic_AVD",
                  model.memoryMB == 4096, model.refreshHz == 60 else { exit(2) }
            print("PASS: separate process reloads saved profile and isolated preferences")
            NSApplication.shared.setActivationPolicy(.prohibited)
            let view = NSHostingView(rootView: ContentView(model: model))
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard bitmap.pixelsWide >= 1000 && bitmap.pixelsHigh >= 720 else { exit(4) }
            print("PASS: restarted SwiftUI root renders saved synthetic model")
            exit(0)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playdesk-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = "PlayDesk.IsolatedSmoke." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: domain) else { fatalError("No isolated defaults") }
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set("Synthetic_AVD", forKey: "selectedAVD")
        defaults.set(2048, forKey: "memoryMB")
        defaults.set(90, forKey: "refreshHz")
        let store = ProfileStore(url: root.appendingPathComponent("profiles.json"))
        try store.save([GameProfile(package: "example.synthetic", name: "Synthetic", mappings: [])])
        let bridge = AndroidBridge(tools: ToolPaths(sdk: nil, adb: nil, emulator: nil, scrcpy: nil))
        let model = LauncherModel(bridge: bridge, store: store, defaults: defaults)
        var failures = 0
        func check(_ result: Bool, _ name: String) {
            print("\(result ? "PASS" : "FAIL"): \(name)")
            if !result { failures += 1 }
        }
        check(model.selectedAVD == "Synthetic_AVD", "read only injected AVD defaults")
        check(model.memoryMB == 2048 && model.refreshHz == 90, "read injected display preferences")
        model.selectedPackage = "example.synthetic"
        check(model.selectedName == "Synthetic", "load injected synthetic profile")
        model.selectedAVD = "Other_Synthetic_AVD"
        model.memoryMB = 4096
        model.refreshHz = 60
        check(defaults.string(forKey: "selectedAVD") == "Other_Synthetic_AVD", "write injected AVD defaults")
        check(defaults.integer(forKey: "memoryMB") == 4096 && defaults.integer(forKey: "refreshHz") == 60, "write injected preferences")
        model.refresh()
        for _ in 0..<100 where model.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        check(!model.busy && model.status.contains("설치되지"), "missing-tools refresh terminates without external command")
        check(model.devices.isEmpty && model.avds.isEmpty, "no real AVDs or devices discovered")
        model.selectedName = "Edited synthetic"
        model.saveProfile()
        check(try store.load().first?.name == "Edited synthetic", "save only injected temporary profile")
        defaults.synchronize()
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        restart.arguments = ["--verify-restart", root.path, domain]
        let output = Pipe()
        restart.standardOutput = output
        restart.standardError = output
        try restart.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        restart.waitUntilExit()
        print(String(decoding: data, as: UTF8.self))
        check(restart.terminationStatus == 0, "fresh process reload and offscreen SwiftUI smoke exit zero")
        if CommandLine.arguments.contains("--render") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let view = NSHostingView(rootView: ContentView(model: model))
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            check(bitmap != nil, "actual SwiftUI root creates offscreen render buffer")
            if let bitmap {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                check(bitmap.pixelsWide >= 1000 && bitmap.pixelsHigh >= 720, "actual root view renders requested dimensions")
            }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
