import Foundation
import Darwin
import AppKit
import ApplicationServices

/// One authenticated local emulator-console connection for a macro run.
final class EmulatorConsole: @unchecked Sendable {
    private var fd: Int32 = -1
    private let lock = NSLock()

    init(serial: String) throws {
        guard serial.hasPrefix("emulator-"),
              let port = UInt16(serial.dropFirst("emulator-".count)),
              port >= 5554, port % 2 == 0 else {
            throw BridgeError.failed("Android Emulator 시리얼이 올바르지 않습니다: \(serial)")
        }
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.failed("Emulator 콘솔 소켓을 열지 못했습니다.") }
        do {
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) { pointer in
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }
            _ = withUnsafePointer(to: &timeout) { pointer in
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
                throw BridgeError.failed("Emulator 콘솔 주소가 올바르지 않습니다.")
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw BridgeError.failed("Emulator 콘솔에 연결하지 못했습니다.") }
            try readReply()
            let tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".emulator_console_auth_token")
            let token = try String(contentsOf: tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, !token.contains("\n") else {
                throw BridgeError.failed("Emulator 콘솔 인증 토큰이 올바르지 않습니다.")
            }
            try sendCommand("auth \(token)")
        } catch {
            Darwin.close(fd)
            fd = -1
            throw error
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    private func readReply() throws {
        var bytes = [UInt8]()
        for _ in 0..<16_384 {
            var byte: UInt8 = 0
            guard Darwin.recv(fd, &byte, 1, 0) == 1 else {
                throw BridgeError.failed("Emulator 콘솔 응답이 끊겼습니다.")
            }
            bytes.append(byte)
            if byte == 10, let line = String(bytes: bytes, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).last {
                if line == "OK" { return }
                if line.hasPrefix("KO:") { throw BridgeError.failed(String(line)) }
            }
        }
        throw BridgeError.failed("Emulator 콘솔 응답이 너무 깁니다.")
    }

    private func sendCommand(_ command: String) throws {
        let bytes = Array((command + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { pointer in
                Darwin.send(fd, pointer.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            }
            guard count > 0 else { throw BridgeError.failed("Emulator 콘솔에 입력을 보내지 못했습니다.") }
            sent += count
        }
        try readReply()
    }

    func tap(x: Int, y: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try sendCommand("event mouse \(x) \(y) 0 1")
        var pressed = true
        defer { if pressed { try? sendCommand("event mouse \(x) \(y) 0 0") } }
        Thread.sleep(forTimeInterval: 0.055)
        try sendCommand("event mouse \(x) \(y) 0 0")
        pressed = false
    }
}

struct CommandResult {
    let code: Int32
    let output: String
    var ok: Bool { code == 0 }
}

struct ToolPaths: Sendable {
    let sdk: URL?
    let adb: URL?
    let emulator: URL?
    let scrcpy: URL?

    static func discover() -> ToolPaths {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [env["ANDROID_SDK_ROOT"], env["ANDROID_HOME"],
                          home.appendingPathComponent("Library/Android/sdk").path]
            .compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        let sdk = candidates.first { fm.fileExists(atPath: $0.path) }
        func locate(_ name: String, relative: String) -> URL? {
            if let sdk = sdk {
                let url = sdk.appendingPathComponent(relative)
                if fm.isExecutableFile(atPath: url.path) { return url }
            }
            for folder in (env["PATH"] ?? "").split(separator: ":") {
                let url = URL(fileURLWithPath: String(folder)).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: url.path) { return url }
            }
            return nil
        }
        return ToolPaths(sdk: sdk, adb: locate("adb", relative: "platform-tools/adb"),
                         emulator: locate("emulator", relative: "emulator/emulator"),
                         scrcpy: locate("scrcpy", relative: "scrcpy"))
    }
}

enum BridgeError: LocalizedError {
    case missing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): return "\(name)이 설치되지 않았습니다. README의 SDK 설치 방법을 확인하세요."
        case .failed(let message): return message
        }
    }
}

struct EmulatorDevice: Identifiable, Hashable {
    let serial: String
    let avdName: String
    let booted: Bool
    var id: String { serial }
}

struct DisplayInfo: Equatable {
    let nativeWidth: Int
    let nativeHeight: Int
    let width: Int
    let height: Int
    let isOverridden: Bool
}

final class AndroidBridge: Sendable {
    let tools: ToolPaths
    private let touchLock = NSLock()

    init(tools: ToolPaths = .discover()) { self.tools = tools }

    @MainActor func emulatorPID(avd: String, serial: String) throws -> pid_t {
        guard serial.hasPrefix("emulator-"),
              UInt16(serial.dropFirst("emulator-".count)) != nil else {
            throw BridgeError.failed("에뮬레이터 창의 시리얼이 올바르지 않습니다.")
        }
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.executableURL?.lastPathComponent == "qemu-system-aarch64"
        }
        let ps = URL(fileURLWithPath: "/bin/ps")
        let application = try candidates.first { candidate in
            let result = try Self.run(ps, ["-p", String(candidate.processIdentifier), "-o", "command="])
            let words = result.output.split(whereSeparator: \.isWhitespace)
            return zip(words, words.dropFirst()).contains { pair in
                pair.0 == "-avd" && pair.1 == Substring(avd)
            }
        }
        guard let application else {
            throw BridgeError.failed("선택한 AVD의 Emulator 프로세스를 찾지 못했습니다.")
        }
        return application.processIdentifier
    }

    @MainActor func tryActivateEmulator(pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
        if application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) { return true }
        guard AXIsProcessTrusted() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        if AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowValue) == .success,
           let windows = windowValue as? [AXUIElement], let window = windows.first,
           AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
            return true
        }
        return false
    }

    @MainActor func isEmulatorFrontmost(pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(code: process.terminationStatus,
                             output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func adb(_ arguments: [String]) throws -> CommandResult {
        guard let path = tools.adb else { throw BridgeError.missing("adb") }
        return try Self.run(path, arguments)
    }

    func require(_ result: CommandResult) throws -> String {
        guard result.ok else { throw BridgeError.failed(result.output.isEmpty ? "명령 실패 (\(result.code))" : result.output) }
        return result.output
    }

    func avds() throws -> [String] {
        guard let path = tools.emulator else { throw BridgeError.missing("Android Emulator") }
        let output = try require(Self.run(path, ["-list-avds"]))
        return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    func devices() throws -> [EmulatorDevice] {
        let output = try require(adb(["devices"]))
        let serials = output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0].hasPrefix("emulator-"), parts[1] == "device" else { return nil }
            return String(parts[0])
        }
        return serials.map { serial in
            let nameOutput = (try? adb(["-s", serial, "emu", "avd", "name"]).output) ?? ""
            let name = nameOutput.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != "OK" } ?? serial
            let boot = (try? adb(["-s", serial, "shell", "getprop", "sys.boot_completed"]).output) == "1"
            return EmulatorDevice(serial: serial, avdName: name, booted: boot)
        }
    }

    func start(avd: String, memoryMB: Int) throws {
        guard let path = tools.emulator else { throw BridgeError.missing("Android Emulator") }
        guard (1536...8192).contains(memoryMB) else { throw BridgeError.failed("메모리는 1536~8192MB여야 합니다.") }
        try enableHostKeyboard(avd: avd)
        let process = Process()
        process.executableURL = path
        process.arguments = ["-avd", avd, "-memory", String(memoryMB), "-gpu", "auto", "-no-snapshot"]
        if let partitionMB = try lowDiskPartitionOverride(avd: avd) {
            process.arguments! += ["-partition-size", String(partitionMB)]
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AdFreeAndroidLauncher")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let log = support.appendingPathComponent("emulator-start.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try? handle.close()
        Thread.sleep(forTimeInterval: 0.8)
        if !process.isRunning {
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let lastLine = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "알 수 없는 시작 오류"
            throw BridgeError.failed("에뮬레이터가 바로 종료됐습니다: \(lastLine) (로그: \(log.path))")
        }
    }

    /// Android's AVD template can disable the Mac keyboard even when a keyboard is attached.
    /// Apply this before launch because a running emulator reads config.ini only at boot.
    private func avdConfigURL(avd: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let avdHome = environment["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd")
        let descriptor = avdHome.appendingPathComponent(avd + ".ini")
        let definition = try String(contentsOf: descriptor, encoding: .utf8)
        guard let path = definition.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("path=") })?.dropFirst("path=".count), !path.isEmpty else {
            throw BridgeError.failed("AVD 설정 파일의 경로를 찾지 못했습니다: \(descriptor.path)")
        }
        return URL(fileURLWithPath: String(path)).appendingPathComponent("config.ini")
    }

    private func enableHostKeyboard(avd: String) throws {
        let configURL = try avdConfigURL(avd: avd)
        var config = try String(contentsOf: configURL, encoding: .utf8)
        var lines = config.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix("hw.keyboard=") }) {
            if lines[index] == "hw.keyboard=yes" { return }
            lines[index] = "hw.keyboard=yes"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("hw.keyboard=yes")
        }
        config = lines.joined(separator: "\n") + "\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// The emulator checks free host space against its configured partition size even
    /// when the persistent user-data image already exists. Limit that startup check
    /// on a low-space Mac without resizing or replacing the existing image.
    private func lowDiskPartitionOverride(avd: String) throws -> Int? {
        let configURL = try avdConfigURL(avd: avd)
        let config = try String(contentsOf: configURL, encoding: .utf8)
        guard let line = config.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("disk.dataPartition.size=") }) else { return nil }
        let value = String(line.dropFirst("disk.dataPartition.size=".count)).uppercased()
        let configuredMB: Int?
        if value.hasSuffix("G"), let count = Int(value.dropLast()) { configuredMB = count * 1024 }
        else if value.hasSuffix("M"), let count = Int(value.dropLast()) { configuredMB = count }
        else { configuredMB = Int(value).map { $0 / 1_048_576 } }
        guard let configuredMB else { return nil }
        let avdDirectory = configURL.deletingLastPathComponent()
        let dataImage = avdDirectory.appendingPathComponent("userdata-qemu.img.qcow2")
        guard FileManager.default.fileExists(atPath: dataImage.path) else { return nil }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: avdDirectory.path)
        guard let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else { return nil }
        let freeMB = Int(freeBytes / 1_048_576)
        guard freeMB < configuredMB + 512 else { return nil }
        let overrideMB = min(configuredMB, max(0, (freeMB - 512) / 1024) * 1024)
        guard overrideMB >= 2048 else {
            throw BridgeError.failed("에뮬레이터를 시작할 저장 공간이 부족합니다. Mac 저장 공간을 확보하세요.")
        }
        return overrideMB
    }

    func stop(serial: String) throws {
        _ = try require(adb(["-s", serial, "emu", "kill"]))
    }

    func install(apk: URL, serial: String) throws -> String {
        try require(adb(["-s", serial, "install", "-r", apk.path]))
    }

    func packages(serial: String) throws -> [String] {
        let output = try require(adb(["-s", serial, "shell", "pm", "list", "packages", "-3"]))
        return output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = String(line)
            return value.hasPrefix("package:") ? String(value.dropFirst(8)) : nil
        }.sorted()
    }

    func hasPlayStore(serial: String) throws -> Bool {
        let output = try require(adb(["-s", serial, "shell", "pm", "list", "packages", "com.android.vending"]))
        return output.split(whereSeparator: \.isNewline).contains("package:com.android.vending")
    }

    func displayInfo(serial: String) throws -> DisplayInfo? {
        let output = try require(adb(["-s", serial, "shell", "wm", "size"]))
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        func dimensions(_ prefix: String) -> (Int, Int)? {
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }),
                  let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
            let parts = value.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
            return (width, height)
        }
        guard let native = dimensions("Physical size:") else { return nil }
        let override = dimensions("Override size:")
        return DisplayInfo(nativeWidth: native.0, nativeHeight: native.1,
                           width: override?.0 ?? native.0, height: override?.1 ?? native.1,
                           isOverridden: override != nil)
    }

    func openPlayStore(serial: String) throws {
        guard try hasPlayStore(serial: serial) else {
            throw BridgeError.failed("이 AVD에는 Play Store가 없습니다. Google Play 포함 ARM64 이미지로 AVD를 만드세요.")
        }
        _ = try launch(package: "com.android.vending", serial: serial)
    }

    func launch(package: String, serial: String) throws -> String {
        // adb shell may interpret its joined arguments remotely; Process argv alone
        // is not a validation boundary for imported profile/package strings.
        guard package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$"#,
                            options: .regularExpression) != nil,
              !package.contains("\n"), !package.contains("\r") else {
            throw BridgeError.failed("Android 패키지 이름이 올바르지 않습니다.")
        }
        let resolution = try require(adb(["-s", serial, "shell", "cmd", "package", "resolve-activity",
                                          "--brief", "-a", "android.intent.action.MAIN",
                                          "-c", "android.intent.category.LAUNCHER", package]))
        guard let component = resolution.split(whereSeparator: \.isNewline).map(String.init)
            .first(where: { $0.hasPrefix(package + "/") }) else {
            throw BridgeError.failed("시작 가능한 Activity가 없는 패키지입니다: \(package)")
        }
        let result = try adb(["-s", serial, "shell", "am", "start", "-n", component])
        let output = try require(result)
        guard !output.contains("Error:") && !output.contains("unable to resolve") else {
            throw BridgeError.failed("시작 가능한 Activity가 없는 패키지입니다: \(package)")
        }
        return output
    }

    /// Uses the emulator's mouse-to-touch path, which is also used by a click in its window.
    /// The console command accepts display pixel coordinates and a touch-screen button mask.
    func hardwareTap(x: Int, y: Int, width: Int, height: Int, serial: String,
                     console: EmulatorConsole? = nil) throws {
        guard width > 0, height > 0, x >= 0, y >= 0, x < width, y < height else {
            throw BridgeError.failed("터치 좌표가 현재 화면 밖에 있습니다.")
        }
        touchLock.lock()
        defer { touchLock.unlock() }
        let connection: EmulatorConsole
        if let console { connection = console } else { connection = try EmulatorConsole(serial: serial) }
        try connection.tap(x: x, y: y)
    }

    func foregroundPackage(serial: String) throws -> String? {
        let output = try require(adb(["-s", serial, "shell", "dumpsys", "activity", "activities"]))
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("topResumedActivity=") }),
              let component = line.split(whereSeparator: \.isWhitespace).first(where: { $0.contains("/") }) else {
            return nil
        }
        return component.split(separator: "/").first.map(String.init)
    }

    func applyDisplay(serial: String, width: Int, height: Int, refreshHz: Int) throws {
        guard (320...3840).contains(width), (320...3840).contains(height) else {
            throw BridgeError.failed("해상도는 각 변이 320~3840px이어야 합니다.")
        }
        guard (30...120).contains(refreshHz) else { throw BridgeError.failed("주사율 목표는 30~120Hz여야 합니다.") }
        _ = try require(adb(["-s", serial, "shell", "wm", "size", "\(width)x\(height)"]))
        _ = try require(adb(["-s", serial, "shell", "settings", "put", "system",
                             "peak_refresh_rate", "\(refreshHz).0"]))
    }

    func resetDisplay(serial: String) throws {
        _ = try require(adb(["-s", serial, "shell", "wm", "size", "reset"]))
    }

    func screenshot(serial: String) throws -> Data {
        guard let path = tools.adb else { throw BridgeError.missing("adb") }
        let process = Process()
        process.executableURL = path
        process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw BridgeError.failed("화면을 가져오지 못했습니다.")
        }
        return data
    }
}
