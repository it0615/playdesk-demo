import AppKit
import ApplicationServices
import Foundation

private actor MacroForegroundWatch {
    private var failure: String?
    func fail(_ message: String) { failure = message }
    func reason() -> String? { failure }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var avds: [String] = []
    @Published var selectedAVD = "" {
        didSet {
            if selectedAVD != oldValue {
                stopMacro()
                defaults.set(selectedAVD, forKey: "selectedAVD")
                screenImage = nil
            }
        }
    }
    @Published var devices: [EmulatorDevice] = []
    @Published var packages: [String] = []
    @Published var playStoreAvailable = false
    @Published var selectedPackage = "" {
        didSet {
            if selectedPackage != oldValue {
                stopMacro()
                loadSelectedProfile()
                screenImage = nil
            }
        }
    }
    @Published var selectedName = ""
    @Published var memoryMB = 4096 {
        didSet { defaults.set(memoryMB, forKey: "memoryMB") }
    }
    @Published var width = 1080
    @Published var height = 1920
    @Published var refreshHz = 60 {
        didSet { defaults.set(refreshHz, forKey: "refreshHz") }
    }
    @Published var displayInfo: DisplayInfo?
    @Published var screenImage: NSImage?
    @Published var screenWidth = 0
    @Published var screenHeight = 0
    @Published var mappings: [KeyMapping] = []
    @Published var macros: [ClickMacro] = []
    @Published var editingMacro = ClickMacro(name: "새 매크로", steps: [], repeatCount: 5,
                                             intervalMs: 500, referenceWidth: 1080, referenceHeight: 1920)
    @Published var macroRunning = false
    @Published var macroProgress = ""
    @Published var status = "SDK 상태를 확인하세요."
    @Published var busy = false
    @Published var backgroundKeys = false
    @Published var captureArmed = false
    @Published var lastKey = ""

    let bridge: AndroidBridge
    let store: ProfileStore
    private let defaults: UserDefaults
    private var profiles: [GameProfile] = []
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var macroTask: Task<Void, Never>?
    private var macroRunID: UUID?

    var selectedDevice: EmulatorDevice? {
        devices.first { $0.avdName == selectedAVD }
    }
    var readySerial: String? {
        guard let device = selectedDevice, device.booted else { return nil }
        return device.serial
    }
    var sdkSummary: String {
        let paths = bridge.tools
        return "SDK: \(paths.sdk?.path ?? "없음")  ·  adb: \(paths.adb == nil ? "없음" : "있음")  ·  emulator: \(paths.emulator == nil ? "없음" : "있음")  ·  scrcpy: \(paths.scrcpy == nil ? "없음" : "있음")"
    }
    var resolutionNeedsApply: Bool {
        guard let info = displayInfo else { return false }
        return width != info.width || height != info.height
    }
    var activeWidth: Int { screenImage == nil ? (displayInfo?.width ?? width) : screenWidth }
    var activeHeight: Int { screenImage == nil ? (displayInfo?.height ?? height) : screenHeight }
    var hasUnsavedProfile: Bool {
        let saved = profiles.first { $0.package == selectedPackage }
        return mappings != (saved?.mappings ?? []) ||
            selectedName.trimmingCharacters(in: .whitespacesAndNewlines) != (saved?.name ?? "")
    }
    var hasUnsavedMacro: Bool {
        editingMacro != macros.first(where: { $0.id == editingMacro.id })
    }
    func displayName(for package: String) -> String {
        if let name = profiles.first(where: { $0.package == package })?.name, !name.isEmpty { return name }
        return package.split(separator: ".").suffix(2).joined(separator: ".")
    }

    init(bridge: AndroidBridge = AndroidBridge(), store: ProfileStore = ProfileStore(),
         defaults: UserDefaults = .standard) {
        self.bridge = bridge
        self.store = store
        self.defaults = defaults
        selectedAVD = defaults.string(forKey: "selectedAVD") ?? ""
        do { profiles = try store.load() }
        catch { status = "프로필 로드 실패: \(error.localizedDescription)" }
        let savedMemory = defaults.integer(forKey: "memoryMB")
        if [2048, 4096, 6144, 8192].contains(savedMemory) { memoryMB = savedMemory }
        let savedRefresh = defaults.integer(forKey: "refreshHz")
        if [30, 60, 90, 120].contains(savedRefresh) { refreshHz = savedRefresh }
    }

    private func work(_ label: String, task: @escaping () throws -> String,
                      done: (() -> Void)? = nil, silent: Bool = false) {
        guard !busy else { return }
        busy = true
        if !silent { status = "\(label) 중…" }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try task() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let message):
                    if !silent { self.status = message.isEmpty ? "\(label) 완료" : message }
                    done?()
                case .failure(let error):
                    self.status = "\(label) 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func refresh(silent: Bool = false) {
        let bridge = bridge
        let selected = selectedAVD
        work("기기 확인", task: {
            let avds = try bridge.avds()
            let devices = try bridge.devices()
            let chosen = avds.contains(selected) ? selected : (avds.first ?? "")
            let serial = devices.first { $0.avdName == chosen && $0.booted }?.serial
            let packages = try serial.map { try bridge.packages(serial: $0) } ?? []
            let playStore = try serial.map { try bridge.hasPlayStore(serial: $0) } ?? false
            let display = try serial.flatMap { try bridge.displayInfo(serial: $0) }
            DispatchQueue.main.async {
                self.avds = avds
                if self.selectedAVD != chosen { self.selectedAVD = chosen }
                self.devices = devices
                self.packages = packages
                self.playStoreAvailable = playStore
                self.displayInfo = display
                if let display = display { self.width = display.width; self.height = display.height }
                if !packages.contains(self.selectedPackage) {
                    self.selectedPackage = packages.first ?? ""
                }
                if serial != nil && self.status == "시작 요청 완료. 부팅 상태를 확인하는 중입니다." {
                    self.status = "AVD \(chosen): 부팅 완료 (\(serial!))"
                }
            }
            if avds.isEmpty { return "AVD가 없습니다. README에 따라 ARM64 AVD를 만드세요." }
            return serial == nil ? "AVD \(chosen): 꺼짐 또는 부팅 중" : "AVD \(chosen): 부팅 완료 (\(serial!))"
        }, silent: silent)
    }

    func start() {
        let avd = selectedAVD
        let memory = memoryMB
        let bridge = bridge
        guard !avd.isEmpty else { status = "먼저 AVD를 선택하세요."; return }
        guard selectedDevice == nil else { status = "선택한 AVD가 이미 실행 중입니다."; return }
        work("에뮬레이터 시작", task: {
            try bridge.start(avd: avd, memoryMB: memory)
            return "시작 요청 완료. 부팅 상태를 확인하는 중입니다."
        }, done: { self.refresh(silent: true) })
    }

    func stop() {
        guard let serial = selectedDevice?.serial else { status = "실행 중인 선택 AVD가 없습니다."; return }
        stopMacro()
        let bridge = bridge
        work("에뮬레이터 종료", task: {
            try bridge.stop(serial: serial)
            return "종료 요청 완료: \(serial)"
        }, done: { self.refresh(silent: true) })
    }

    func install(_ url: URL) {
        guard let serial = readySerial else { status = "AVD 부팅이 끝나야 APK를 설치할 수 있습니다."; return }
        let bridge = bridge
        work("APK 설치", task: {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            _ = try bridge.install(apk: url, serial: serial)
            return "APK 설치 완료 · \(url.lastPathComponent)"
        }, done: { self.refresh(silent: true) })
    }

    func launch() {
        guard let serial = readySerial, !selectedPackage.isEmpty else { status = "부팅된 AVD와 앱을 선택하세요."; return }
        let package = selectedPackage
        let bridge = bridge
        work("앱 실행", task: {
            _ = try bridge.launch(package: package, serial: serial)
            return "실행 요청 완료: \(package)"
        }, done: { self.clearScreen() })
    }

    func openPlayStore() {
        guard let serial = readySerial else { status = "AVD 부팅이 끝나야 Play Store를 열 수 있습니다."; return }
        let bridge = bridge
        work("Play Store 열기", task: {
            try bridge.openPlayStore(serial: serial)
            return "Play Store 실행 요청 완료. 에뮬레이터 창에서 확인하세요."
        })
    }

    func applyDisplay() {
        guard let serial = readySerial else { status = "AVD 부팅이 끝나야 화면 설정을 적용할 수 있습니다."; return }
        let bridge = bridge
        let width = width, height = height, hz = refreshHz
        work("화면 설정", task: {
            try bridge.applyDisplay(serial: serial, width: width, height: height, refreshHz: hz)
            return "화면 크기 \(width)×\(height), 주사율 목표 \(hz)Hz 적용"
        }, done: { self.clearScreen(); self.refresh(silent: true) })
    }

    func setResolutionScale(_ scale: Double) {
        guard let info = displayInfo else { return }
        width = max(320, Int((Double(info.nativeWidth) * scale / 2).rounded()) * 2)
        height = max(320, Int((Double(info.nativeHeight) * scale / 2).rounded()) * 2)
    }

    func resetDisplay() {
        guard let serial = readySerial else { status = "부팅된 AVD를 선택하세요."; return }
        let bridge = bridge
        work("기본 해상도 복원", task: {
            try bridge.resetDisplay(serial: serial)
            return "기기 원본 해상도로 복원했습니다."
        }, done: { self.clearScreen(); self.refresh(silent: true) })
    }

    func captureScreen() {
        guard let serial = readySerial else { status = "부팅된 AVD를 선택하세요."; return }
        let bridge = bridge
        let package = selectedPackage
        work("화면 가져오기", task: {
            guard try bridge.foregroundPackage(serial: serial) == package else {
                throw BridgeError.failed("선택한 앱을 먼저 실행한 뒤 화면을 가져오세요.")
            }
            let data = try bridge.screenshot(serial: serial)
            DispatchQueue.main.async {
                guard self.selectedPackage == package else { return }
                self.screenImage = NSImage(data: data)
                if let bitmap = NSBitmapImageRep(data: data) {
                    self.screenWidth = bitmap.pixelsWide
                    self.screenHeight = bitmap.pixelsHigh
                }
            }
            return "현재 Android 화면을 가져왔습니다."
        })
    }

    private func clearScreen() {
        screenImage = nil
        screenWidth = 0
        screenHeight = 0
    }

    func setMappingCoordinate(id: UUID, normalizedX: Double, normalizedY: Double) {
        guard let index = mappings.firstIndex(where: { $0.id == id }), activeWidth > 0, activeHeight > 0 else { return }
        mappings[index].x = min(activeWidth - 1, max(0, Int(normalizedX * Double(activeWidth))))
        mappings[index].y = min(activeHeight - 1, max(0, Int(normalizedY * Double(activeHeight))))
        status = "좌표 선택: (\(mappings[index].x), \(mappings[index].y)) · 프로필을 저장하세요."
    }

    private func loadSelectedProfile() {
        let profile = profiles.first { $0.package == selectedPackage }
        mappings = profile?.mappings ?? []
        selectedName = profile?.name ?? ""
        macros = profile?.macros ?? []
        newMacro()
        if let first = macros.first { editingMacro = first }
    }

    func addMapping() { mappings.append(KeyMapping(key: "", x: activeWidth / 2, y: activeHeight / 2)) }
    func removeMapping(_ id: UUID) { mappings.removeAll { $0.id == id } }

    func saveProfile() {
        guard !selectedPackage.isEmpty else { status = "패키지를 먼저 선택하세요."; return }
        let normalized = mappings.map {
            KeyMapping(id: $0.id, key: $0.key.trimmingCharacters(in: .whitespaces).lowercased(), x: $0.x, y: $0.y)
        }
        let keys = normalized.map(\.key)
        guard keys.allSatisfy({ $0.count == 1 }), Set(keys).count == keys.count,
              normalized.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x < activeWidth && $0.y < activeHeight }) else {
            status = "키는 중복 없는 한 글자여야 하고, 좌표는 설정한 화면 안에 있어야 합니다."
            return
        }
        let name = selectedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = GameProfile(package: selectedPackage, name: name.isEmpty ? nil : name,
                                  mappings: normalized, macros: macros)
        var updated = profiles.filter { $0.package != selectedPackage }
        updated.append(profile)
        do {
            try store.save(updated)
            profiles = updated
            mappings = normalized
            status = "프로필 저장 완료: \(store.url.path)"
        } catch { status = "프로필 저장 실패: \(error.localizedDescription)" }
    }

    func newMacro() {
        editingMacro = ClickMacro(name: "새 매크로", steps: [], repeatCount: 5, intervalMs: 500,
                                  referenceWidth: max(1, activeWidth), referenceHeight: max(1, activeHeight))
    }

    func selectMacro(_ id: UUID) {
        guard !macroRunning, let macro = macros.first(where: { $0.id == id }) else { return }
        editingMacro = macro
    }

    func addMacroStep() {
        guard editingMacro.steps.count < 32 else { status = "클릭은 최대 32개까지 추가할 수 있습니다."; return }
        editingMacro.steps.append(MacroStep(x: editingMacro.referenceWidth / 2,
                                            y: editingMacro.referenceHeight / 2))
    }

    func removeMacroStep(_ id: UUID) {
        editingMacro.steps.removeAll { $0.id == id }
    }

    func setMacroCoordinate(id: UUID, normalizedX: Double, normalizedY: Double) {
        guard let index = editingMacro.steps.firstIndex(where: { $0.id == id }) else { return }
        let width = editingMacro.referenceWidth, height = editingMacro.referenceHeight
        editingMacro.steps[index].x = min(width - 1, max(0, Int(normalizedX * Double(width))))
        editingMacro.steps[index].y = min(height - 1, max(0, Int(normalizedY * Double(height))))
        status = "클릭 \(index + 1) 위치를 지정했습니다."
    }

    private func validatedMacro() -> ClickMacro? {
        var macro = editingMacro
        macro.name = macro.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedPackage.isEmpty, !macro.name.isEmpty, macro.name.count <= 40,
              !macro.steps.isEmpty, macro.steps.count <= 32,
              (macro.repeatForever || (1...999).contains(macro.repeatCount)),
              (50...10000).contains(macro.intervalMs),
              macro.referenceWidth > 0, macro.referenceHeight > 0,
              macro.steps.allSatisfy({ $0.x >= 0 && $0.y >= 0 &&
                  $0.x < macro.referenceWidth && $0.y < macro.referenceHeight }) else {
            status = "이름, 클릭 좌표, 반복(1~999), 간격(50~10000ms)을 확인하세요."
            return nil
        }
        return macro
    }

    func saveMacro() {
        guard !macroRunning, let macro = validatedMacro() else { return }
        let saved = profiles.first { $0.package == selectedPackage }
        var updatedMacros = macros.filter { $0.id != macro.id }
        updatedMacros.append(macro)
        let profile = GameProfile(package: selectedPackage, name: saved?.name,
                                  mappings: saved?.mappings ?? [], macros: updatedMacros)
        var updatedProfiles = profiles.filter { $0.package != selectedPackage }
        updatedProfiles.append(profile)
        do {
            try store.save(updatedProfiles)
            profiles = updatedProfiles
            macros = updatedMacros
            editingMacro = macro
            status = "매크로 저장 완료: \(macro.name)"
        } catch { status = "매크로 저장 실패: \(error.localizedDescription)" }
    }

    func deleteMacro() {
        guard !macroRunning, let saved = profiles.first(where: { $0.package == selectedPackage }),
              saved.macros.contains(where: { $0.id == editingMacro.id }) else { return }
        var profile = saved
        profile.macros.removeAll { $0.id == editingMacro.id }
        var updatedProfiles = profiles.filter { $0.package != selectedPackage }
        updatedProfiles.append(profile)
        do {
            try store.save(updatedProfiles)
            profiles = updatedProfiles
            macros = profile.macros
            newMacro()
            if let first = macros.first { editingMacro = first }
            status = "매크로를 삭제했습니다."
        } catch { status = "매크로 삭제 실패: \(error.localizedDescription)" }
    }

    func runMacro(once: Bool = false) {
        guard !macroRunning, let serial = readySerial, let macro = validatedMacro() else {
            if readySerial == nil { status = "부팅된 AVD가 필요합니다." }
            return
        }
        let emulatorPID: pid_t
        do { emulatorPID = try bridge.emulatorPID(avd: selectedAVD, serial: serial) }
        catch { status = "매크로 시작 실패: \(error.localizedDescription)"; return }
        let focused = macro.continueInBackground || bridge.tryActivateEmulator(pid: emulatorPID)
        let package = selectedPackage
        let width = activeWidth, height = activeHeight
        let cycles: Int? = once ? 1 : (macro.repeatForever ? nil : macro.repeatCount)
        let bridge = bridge
        let runID = UUID()
        macroRunID = runID
        macroRunning = true
        macroProgress = focused ? "대상 앱 확인 중" : "에뮬레이터 창을 클릭하면 시작합니다"
        status = macro.continueInBackground ? "다른 Mac 창에서도 매크로 실행 중…" :
            (focused ? "가상 터치 장치로 매크로 실행 중…" : "에뮬레이터 창을 클릭하면 매크로가 시작됩니다.")
        macroTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: String
            do {
                if !macro.continueInBackground {
                    let focusDeadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
                    while !(await bridge.isEmulatorFrontmost(pid: emulatorPID)) {
                        try Task.checkCancellation()
                        guard DispatchTime.now().uptimeNanoseconds < focusDeadline else {
                            throw BridgeError.failed("30초 동안 에뮬레이터 창이 활성화되지 않았습니다.")
                        }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                guard try bridge.foregroundPackage(serial: serial) == package else {
                    throw BridgeError.failed("대상 앱이 화면에 없습니다. 앱 실행 후 다시 시작하세요.")
                }
                let console = try EmulatorConsole(serial: serial)
                let foregroundWatch = MacroForegroundWatch()
                let monitor = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 500_000_000) }
                        catch { break }
                        do {
                            if try bridge.foregroundPackage(serial: serial) != package {
                                await foregroundWatch.fail("대상 앱이 화면에서 벗어나 매크로를 중지했습니다.")
                                break
                            }
                        } catch {
                            await foregroundWatch.fail("실행 중인 앱을 확인하지 못해 매크로를 중지했습니다.")
                            break
                        }
                    }
                }
                defer { monitor.cancel() }
                let intervalNs = UInt64(macro.intervalMs) * 1_000_000
                var nextTick = DispatchTime.now().uptimeNanoseconds
                var firstTap: UInt64?
                var lastTap: UInt64?
                var completed = 0
                var cycle = 0
                while true {
                    if let cycles {
                        if cycle >= cycles { break }
                        cycle += 1
                    }
                    for (index, step) in macro.steps.enumerated() {
                        try Task.checkCancellation()
                        let now = DispatchTime.now().uptimeNanoseconds
                        if nextTick > now { try await Task.sleep(nanoseconds: nextTick - now) }
                        try Task.checkCancellation()
                        if let reason = await foregroundWatch.reason() {
                            throw BridgeError.failed(reason)
                        }
                        if !macro.continueInBackground && completed > 0 &&
                           completed % max(1, 1000 / macro.intervalMs) == 0,
                           !(await bridge.isEmulatorFrontmost(pid: emulatorPID)) {
                            if let owner = self {
                                await MainActor.run { owner.macroProgress = "에뮬레이터 창 활성화 대기 중" }
                            }
                            let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
                            while !(await bridge.isEmulatorFrontmost(pid: emulatorPID)) {
                                try Task.checkCancellation()
                                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                                    throw BridgeError.failed("30초 동안 에뮬레이터 창이 활성화되지 않았습니다.")
                                }
                                try await Task.sleep(nanoseconds: 250_000_000)
                            }
                            nextTick = DispatchTime.now().uptimeNanoseconds
                        }
                        let x = min(width - 1, Int(Double(step.x) * Double(width) / Double(macro.referenceWidth)))
                        let y = min(height - 1, Int(Double(step.y) * Double(height) / Double(macro.referenceHeight)))
                        let tapStart = DispatchTime.now().uptimeNanoseconds
                        if firstTap == nil { firstTap = tapStart }
                        try bridge.hardwareTap(x: x, y: y, width: width, height: height,
                                               serial: serial, console: console)
                        completed += 1
                        lastTap = tapStart
                        nextTick = max(nextTick + intervalNs, tapStart + intervalNs / 2)
                        if let owner = self {
                            let progress = if let cycles {
                                "\(cycle)/\(cycles)회 · 클릭 \(index + 1)/\(macro.steps.count)"
                            } else {
                                "무한 반복 · \(completed)번 클릭 · 중지 버튼으로 종료"
                            }
                            await MainActor.run { owner.macroProgress = progress }
                        }
                    }
                }
                if completed > 1, let firstTap, let lastTap, lastTap > firstTap {
                    let rate = Double(completed - 1) * 1_000_000_000 / Double(lastTap - firstTap)
                    result = "매크로 완료: \(completed)번 클릭 · 시작 간격 평균 \(String(format: "%.1f", rate))회/초"
                } else {
                    result = "매크로 완료: \(completed)번 클릭"
                }
            } catch is CancellationError {
                result = "매크로를 중지했습니다."
            } catch {
                result = "매크로 실패: \(error.localizedDescription)"
            }
            if let owner = self {
                await MainActor.run {
                    guard owner.macroRunID == runID else { return }
                    owner.macroRunning = false
                    owner.macroTask = nil
                    owner.macroRunID = nil
                    owner.macroProgress = ""
                    owner.status = result
                }
            }
        }
    }

    func stopMacro() {
        guard macroRunning else { return }
        macroTask?.cancel()
        status = "매크로 중지 중…"
    }

    func handleKey(_ input: String) {
        let key = input.lowercased()
        guard let mapping = mappings.first(where: { $0.key.lowercased() == key }),
              let serial = readySerial else { return }
        lastKey = "\(key) → (\(mapping.x), \(mapping.y))"
        let bridge = bridge
        let width = activeWidth, height = activeHeight
        DispatchQueue.global(qos: .userInitiated).async {
            do { try bridge.hardwareTap(x: mapping.x, y: mapping.y, width: width, height: height, serial: serial) }
            catch { DispatchQueue.main.async { self.status = "키 입력 실패: \(error.localizedDescription)" } }
        }
    }

    func toggleKeyCapture() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
            captureArmed = false
            status = "키 입력 영역을 껐습니다."
            return
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let key = event.charactersIgnoringModifiers else { return event }
            if event.keyCode == 53 {
                DispatchQueue.main.async { self.toggleKeyCapture() }
                return nil
            }
            guard self.mappings.contains(where: { $0.key.lowercased() == key.lowercased() }) else { return event }
            DispatchQueue.main.async { self.handleKey(key) }
            return nil
        }
        captureArmed = localKeyMonitor != nil
        status = captureArmed ? "키 입력 준비 완료. 저장한 키를 누르세요." : "키 입력을 시작하지 못했습니다."
    }

    func setBackgroundKeys(_ enabled: Bool) {
        if !enabled {
            if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            backgroundKeys = false
            status = "백그라운드 키 입력을 껐습니다."
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            backgroundKeys = false
            status = "macOS 손쉬운 사용 권한을 허용한 뒤 다시 켜세요."
            return
        }
        guard let serial = readySerial,
              let pid = try? bridge.emulatorPID(avd: selectedAVD, serial: serial) else {
            backgroundKeys = false
            status = "먼저 선택한 에뮬레이터를 실행하세요."
            return
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let key = event.charactersIgnoringModifiers else { return }
            DispatchQueue.main.async {
                guard let self, self.backgroundKeys, !NSApp.isActive,
                      self.readySerial == serial, self.bridge.isEmulatorFrontmost(pid: pid) else { return }
                self.handleKey(key)
            }
        }
        backgroundKeys = keyMonitor != nil
        status = backgroundKeys ? "에뮬레이터 창에서 키 매핑을 켰습니다." : "키 모니터를 시작하지 못했습니다."
    }

    deinit {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localKeyMonitor = localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}
