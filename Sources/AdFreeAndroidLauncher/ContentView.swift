import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LauncherPage: String, CaseIterable, Identifiable {
    case library, device, controls, macros
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return "게임 라이브러리"
        case .device: return "기기 및 화면"
        case .controls: return "키 매핑"
        case .macros: return "클릭 매크로"
        }
    }
    var icon: String {
        switch self {
        case .library: return "square.grid.2x2.fill"
        case .device: return "display"
        case .controls: return "keyboard"
        case .macros: return "hand.tap.fill"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: LauncherModel
    @State private var page: LauncherPage = .library
    @State private var apkPicker = false
    @State private var search = ""
    @State private var chosenMapping: UUID?
    @State private var chosenMacroStep: UUID?
    @State private var confirmMacroDelete = false
    private let purple = Color(red: 0.43, green: 0.39, blue: 0.96)
    private var filtered: [String] { model.packages.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        switch page {
                        case .library: library
                        case .device: device
                        case .controls: controls
                        case .macros: macroPage
                        }
                    }
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 25)
                }
                statusBar
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(isPresented: $apkPicker, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data]) { result in
            switch result {
            case .success(let url): model.install(url)
            case .failure(let error): model.status = "APK 선택 실패: \(error.localizedDescription)"
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: model.selectedAVD) { _ in model.refresh(silent: true) }
        .onChange(of: model.selectedPackage) { _ in chosenMapping = nil; chosenMacroStep = nil }
        .onChange(of: page) { next in
            if next != .controls && model.captureArmed { model.toggleKeyCapture() }
        }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            if !model.busy && !model.selectedAVD.isEmpty && model.selectedDevice?.booted != true {
                model.refresh(silent: true)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(LinearGradient(colors: [purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text("PLAYDESK").font(.system(size: 15, weight: .heavy, design: .rounded))
                    Text("Android on Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 34)
            Text("WORKSPACE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4).foregroundStyle(.tertiary)
                .padding(.horizontal, 11).padding(.bottom, 8)
            ForEach(LauncherPage.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon).frame(width: 18)
                        Text(item.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: page == item ? .semibold : .medium))
                    .foregroundColor(page == item ? purple : .primary)
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(page == item ? purple.opacity(0.13) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 4)
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(model.readySerial == nil ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(model.readySerial == nil ? "기기 연결 대기" : "Android 실행 중")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(model.selectedAVD.isEmpty ? "AVD가 없습니다" : model.selectedAVD)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Button("기기 설정 열기") { page = .device }.font(.system(size: 11)).buttonStyle(.link)
                if model.macroRunning {
                    Text(model.macroProgress).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("매크로 중지") { model.stopMacro() }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                        .buttonStyle(.plain)
                }
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            Text("광고 · 계정 · 분석 수집 없음")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.top, 14).padding(.leading, 4)
        }
        .padding(18).frame(width: 214)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refresh() } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered).disabled(model.busy)
        }
    }
    private var subtitle: String {
        switch page {
        case .library: return "Play Store와 APK에서 게임을 설치하고 바로 실행하세요."
        case .device: return "가상 기기와 화면 크기를 한곳에서 관리하세요."
        case .controls: return "게임 화면을 보고 키마다 터치 위치를 지정하세요."
        case .macros: return "가상 터치 장치로 여러 위치를 순서대로 클릭하세요."
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 38, weight: .ultraLight))
                    .frame(width: 62, height: 86)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.readySerial == nil ? "가상 기기가 준비되어 있습니다" : "Android가 실행 중입니다")
                        .font(.system(size: 19, weight: .bold))
                    Text(model.selectedAVD.isEmpty ? "AVD를 먼저 만드세요" : model.selectedAVD)
                        .font(.system(size: 12)).opacity(0.85).lineLimit(1)
                    if let info = model.displayInfo {
                        Text("현재 화면 \(info.width) × \(info.height)  ·  \(model.readySerial ?? "")")
                            .font(.system(size: 11)).opacity(0.75)
                    }
                }
                Spacer(minLength: 4)
                Button(model.selectedDevice == nil ? "기기 시작" : "기기 종료") {
                    if model.selectedDevice == nil { model.start() } else { model.stop() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(purple)
                .padding(.horizontal, 15).frame(height: 34)
                .background(.white, in: RoundedRectangle(cornerRadius: 9))
                .disabled(model.busy || model.selectedAVD.isEmpty)
            }
            .foregroundStyle(.white).padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [purple, Color(red: 0.27, green: 0.34, blue: 0.69)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20))
            HStack(spacing: 14) {
                QuickAction(symbol: "bag.fill", title: "Play Store", detail: "Android 안에서 앱 찾기", tint: purple,
                            enabled: model.playStoreAvailable && !model.busy) { model.openPlayStore() }
                QuickAction(symbol: "square.and.arrow.down.fill", title: "APK 설치", detail: "내 Mac의 파일에서 설치", tint: .teal,
                            enabled: model.readySerial != nil && !model.busy) { apkPicker = true }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("설치한 앱").font(.system(size: 18, weight: .bold))
                    Text("사용자가 설치한 앱 \(model.packages.count)개").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.packages.isEmpty {
                    TextField("패키지 검색", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
            if model.packages.isEmpty {
                SurfaceCard {
                    VStack(spacing: 12) {
                        Image(systemName: "gamecontroller").font(.system(size: 36, weight: .light)).foregroundStyle(purple)
                        Text("아직 설치한 앱이 없어요").font(.system(size: 16, weight: .semibold))
                        Text(model.readySerial == nil ? "먼저 가상 기기를 시작하세요." : "Play Store에서 내려받거나 APK 파일을 설치하세요.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if model.readySerial == nil {
                            Button("기기 설정으로 이동") { page = .device }.buttonStyle(.borderedProminent).tint(purple)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            } else if filtered.isEmpty {
                SurfaceCard { Text("검색 결과가 없습니다.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20) }
            } else {
                VStack(spacing: 9) {
                    ForEach(filtered, id: \.self) { package in
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller.fill").font(.system(size: 21)).foregroundStyle(purple)
                                .frame(width: 44, height: 44)
                                .background(purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName(for: package))
                                    .font(.system(size: 14, weight: .semibold))
                                Text(package).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("키 설정") { model.selectedPackage = package; page = .controls }.buttonStyle(.bordered)
                            Button("실행") { model.selectedPackage = package; model.launch() }
                                .buttonStyle(.borderedProminent).tint(purple)
                                .disabled(model.busy || model.readySerial == nil)
                        }
                        .padding(13)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private var device: some View {
        VStack(alignment: .leading, spacing: 18) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    heading("가상 기기", icon: "iphone.gen3", detail: "Android Emulator의 ARM64 AVD를 선택합니다.")
                    HStack {
                        Picker("AVD", selection: $model.selectedAVD) {
                            if model.avds.isEmpty { Text("AVD 없음").tag("") }
                            ForEach(model.avds, id: \.self) { Text($0).tag($0) }
                        }.frame(maxWidth: 370)
                        Spacer()
                        Text(model.selectedDevice?.booted == true ? "부팅 완료" : (model.selectedDevice == nil ? "꺼짐" : "부팅 중"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(model.readySerial == nil ? .orange : .green)
                    }
                    HStack {
                        Button("시작") { model.start() }.buttonStyle(.borderedProminent).tint(purple)
                            .disabled(model.busy || model.selectedAVD.isEmpty || model.selectedDevice != nil)
                        Button("종료") { model.stop() }.buttonStyle(.bordered)
                            .disabled(model.busy || model.selectedDevice == nil)
                        if let serial = model.selectedDevice?.serial {
                            Text(serial).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Text("PlayDesk로 시작한 에뮬레이터는 Mac 키보드를 연결합니다. 이전부터 실행 중이었다면 재시작 후 적용됩니다. 게임 터치 조작은 ‘키 매핑’에서 따로 설정합니다.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 17) {
                    heading("화면 해상도", icon: "rectangle.expand.vertical", detail: "원본 화면 비율을 유지하는 프리셋을 선택하세요.")
                    HStack(spacing: 10) {
                        infoPill("기기 원본", value: model.displayInfo.map { "\($0.nativeWidth) × \($0.nativeHeight)" } ?? "—")
                        infoPill("현재 적용", value: model.displayInfo.map { "\($0.width) × \($0.height)" } ?? "—")
                    }
                    HStack(spacing: 8) {
                        preset("원본 100%", scale: 1)
                        preset("균형 75%", scale: 0.75)
                        preset("가벼움 50%", scale: 0.5)
                    }
                    HStack(spacing: 8) {
                        Text("직접 입력").font(.system(size: 12, weight: .medium)).frame(width: 64, alignment: .leading)
                        TextField("가로", value: $model.width, format: .number).frame(width: 95)
                        Text("×").foregroundStyle(.secondary)
                        TextField("세로", value: $model.height, format: .number).frame(width: 95)
                        Text("px").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.resolutionNeedsApply {
                            Text("적용 전").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                        }
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Button("해상도 적용") { model.applyDisplay() }.buttonStyle(.borderedProminent).tint(purple)
                            .disabled(model.busy || model.readySerial == nil)
                        Button("기기 원본으로 복원") { model.resetDisplay() }.buttonStyle(.bordered)
                            .disabled(model.busy || model.readySerial == nil || model.displayInfo?.isOverridden != true)
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 17) {
                    heading("성능", icon: "speedometer", detail: "메모리는 다음 시작에, 주사율 목표는 화면 적용 시 반영됩니다.")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("메모리").font(.system(size: 12, weight: .semibold))
                        Picker("메모리", selection: $model.memoryMB) {
                            ForEach([2048, 4096, 6144, 8192], id: \.self) { Text("\($0 / 1024) GB").tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("화면 주사율 목표").font(.system(size: 12, weight: .semibold))
                        Picker("화면 주사율 목표", selection: $model.refreshHz) {
                            ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) Hz").tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Text("주사율 목표는 게임의 실제 FPS를 보장하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.packages.isEmpty {
                SurfaceCard {
                    VStack(spacing: 12) {
                        Image(systemName: "keyboard").font(.system(size: 32)).foregroundStyle(purple)
                        Text("키를 설정할 앱이 없습니다").font(.system(size: 16, weight: .semibold))
                        Text("앱을 설치한 뒤 여기에서 키와 터치 위치를 연결하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("게임 라이브러리 열기") { page = .library }
                            .buttonStyle(.borderedProminent).tint(purple)
                    }.frame(maxWidth: .infinity).padding(.vertical, 35)
                }
            } else {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "app.fill").foregroundStyle(purple)
                            Picker("설정할 앱", selection: $model.selectedPackage) {
                                ForEach(model.packages, id: \.self) { Text(model.displayName(for: $0)).tag($0) }
                            }
                            Spacer()
                            Button("앱 실행") { model.launch() }.disabled(model.busy || model.readySerial == nil)
                        }
                        HStack {
                            Text("표시 이름").font(.caption).foregroundStyle(.secondary)
                            TextField("게임 이름을 입력하세요", text: $model.selectedName)
                                .textFieldStyle(.roundedBorder)
                            if model.hasUnsavedProfile {
                                Text("저장 전").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            heading("터치 위치", icon: "hand.tap.fill", detail: "키를 고른 뒤 화면을 클릭하세요.")
                            Button { model.captureScreen() } label: {
                                Label(model.screenImage == nil ? "게임 화면 가져오기" : "화면 새로고침", systemImage: "camera.viewfinder")
                            }
                            .frame(maxWidth: .infinity)
                            .disabled(model.busy || model.readySerial == nil)
                            HStack {
                                Spacer()
                                PhonePreview(image: model.screenImage, mappings: model.mappings,
                                             selectedID: chosenMapping, width: model.activeWidth,
                                             height: model.activeHeight) { x, y in
                                    guard let id = chosenMapping else {
                                        model.status = "오른쪽에서 위치를 지정할 키를 먼저 선택하세요."
                                        return
                                    }
                                    model.setMappingCoordinate(id: id, normalizedX: x, normalizedY: y)
                                }
                                Spacer()
                            }
                            Text("현재 화면 \(model.activeWidth) × \(model.activeHeight)px")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(width: 290)
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 14) {
                            heading("키 목록", icon: "keyboard.fill", detail: "한 글자 키를 화면 좌표에 연결합니다.")
                            if model.mappings.isEmpty {
                                Text("등록된 키가 없습니다. 새 키를 추가하세요.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 70)
                            }
                            ForEach($model.mappings) { $mapping in
                                HStack(spacing: 7) {
                                    TextField("키", text: $mapping.key).frame(width: 39)
                                    TextField("X", value: $mapping.x, format: .number).frame(width: 61)
                                    TextField("Y", value: $mapping.y, format: .number).frame(width: 61)
                                    Button { chosenMapping = mapping.id } label: {
                                        Image(systemName: chosenMapping == mapping.id ? "scope" : "viewfinder")
                                    }.buttonStyle(.bordered).help("화면에서 위치 선택")
                                    Button(role: .destructive) {
                                        if chosenMapping == mapping.id { chosenMapping = nil }
                                        model.removeMapping(mapping.id)
                                    } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                                .padding(8)
                                .background(chosenMapping == mapping.id ? purple.opacity(0.11) : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 9))
                            }
                            Button {
                                model.addMapping()
                                chosenMapping = model.mappings.last?.id
                            } label: { Label("키 추가", systemImage: "plus") }
                            Divider()
                            Button("프로필 저장") { model.saveProfile() }
                                .buttonStyle(.borderedProminent).tint(purple)
                                .disabled(model.selectedPackage.isEmpty || !model.hasUnsavedProfile)
                            Button(model.captureArmed ? "키 입력 종료 (Esc)" : "키 입력 테스트") {
                                model.toggleKeyCapture()
                            }.buttonStyle(.bordered)
                            Toggle("에뮬레이터 창에서 키 매핑 사용", isOn: Binding(
                                get: { model.backgroundKeys }, set: { model.setBackgroundKeys($0) }))
                                .font(.system(size: 11))
                            Text("클릭 입력은 연속 이동에 적합하지 않습니다.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if !model.lastKey.isEmpty {
                                Text("최근 입력  \(model.lastKey)")
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(purple)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var macroPreviewMappings: [KeyMapping] {
        let macro = model.editingMacro
        return macro.steps.enumerated().map { index, step in
            KeyMapping(id: step.id, key: String(index + 1),
                       x: Int(Double(step.x) * Double(model.activeWidth) / Double(max(1, macro.referenceWidth))),
                       y: Int(Double(step.y) * Double(model.activeHeight) / Double(max(1, macro.referenceHeight))))
        }
    }

    private var macroPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.packages.isEmpty {
                SurfaceCard {
                    VStack(spacing: 12) {
                        Image(systemName: "hand.tap").font(.system(size: 34)).foregroundStyle(purple)
                        Text("클릭할 앱을 먼저 설치하세요").font(.system(size: 16, weight: .semibold))
                        Button("게임 라이브러리 열기") { page = .library }
                            .buttonStyle(.borderedProminent).tint(purple)
                    }.frame(maxWidth: .infinity).padding(.vertical, 35)
                }
            } else {
                SurfaceCard {
                    HStack {
                        Image(systemName: "app.fill").foregroundStyle(purple)
                        Picker("설정할 앱", selection: $model.selectedPackage) {
                            ForEach(model.packages, id: \.self) { Text(model.displayName(for: $0)).tag($0) }
                        }
                        Spacer()
                        Button("앱 실행") { model.launch() }.disabled(model.busy || model.readySerial == nil)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.path").foregroundStyle(purple)
                            Text("가상 터치 장치").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            if model.macroRunning {
                                Button("중지") { model.stopMacro() }
                                    .buttonStyle(.borderedProminent).tint(.red)
                            } else {
                                Button("1회 테스트") { model.runMacro(once: true) }.buttonStyle(.bordered)
                                    .disabled(model.readySerial == nil || model.editingMacro.steps.isEmpty)
                                Button(model.editingMacro.repeatForever ? "무한 반복 시작" : "매크로 시작") { model.runMacro() }
                                    .buttonStyle(.borderedProminent).tint(purple)
                                    .disabled(model.readySerial == nil || model.editingMacro.steps.isEmpty)
                            }
                        }
                        Text(model.macroRunning ? model.macroProgress :
                             "Android Emulator 콘솔 → 가상 터치 입력 장치. 대상 앱이 화면에 있어야 실행됩니다.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            heading("클릭 위치", icon: "hand.tap.fill", detail: "순서의 클릭을 고르고 화면을 클릭하세요.")
                            Button { model.captureScreen() } label: {
                                Label(model.screenImage == nil ? "게임 화면 가져오기" : "화면 새로고침",
                                      systemImage: "camera.viewfinder")
                            }.frame(maxWidth: .infinity).disabled(model.busy || model.readySerial == nil)
                            HStack {
                                Spacer()
                                PhonePreview(image: model.screenImage, mappings: macroPreviewMappings,
                                             selectedID: chosenMacroStep, width: model.activeWidth,
                                             height: model.activeHeight) { x, y in
                                    guard let id = chosenMacroStep else {
                                        model.status = "오른쪽에서 클릭 순서를 먼저 선택하세요."
                                        return
                                    }
                                    model.setMacroCoordinate(id: id, normalizedX: x, normalizedY: y)
                                }
                                Spacer()
                            }
                            Text("현재 화면 \(model.activeWidth) × \(model.activeHeight)px")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(width: 290)
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 13) {
                            heading("클릭 순서", icon: "list.number", detail: "위에서 아래로 차례대로 누릅니다.")
                            HStack(spacing: 8) {
                                Menu("저장된 매크로") {
                                    ForEach(model.macros) { macro in
                                        Button(macro.name) { model.selectMacro(macro.id); chosenMacroStep = nil }
                                    }
                                }.disabled(model.macros.isEmpty || model.macroRunning)
                                Button("새로 만들기") { model.newMacro(); chosenMacroStep = nil }
                                    .disabled(model.macroRunning)
                            }
                            TextField("매크로 이름", text: $model.editingMacro.name)
                                .textFieldStyle(.roundedBorder).disabled(model.macroRunning)
                            if model.editingMacro.steps.isEmpty {
                                Text("클릭을 추가한 뒤 화면에서 위치를 선택하세요.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            ForEach($model.editingMacro.steps) { $step in
                                HStack(spacing: 6) {
                                    Text("\((model.editingMacro.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1)")
                                        .font(.caption.monospacedDigit()).frame(width: 16)
                                    TextField("X", value: $step.x, format: .number).frame(width: 58)
                                    TextField("Y", value: $step.y, format: .number).frame(width: 58)
                                    Button { chosenMacroStep = step.id } label: {
                                        Image(systemName: chosenMacroStep == step.id ? "scope" : "viewfinder")
                                    }.buttonStyle(.bordered).help("화면에서 위치 선택")
                                    Button(role: .destructive) {
                                        if chosenMacroStep == step.id { chosenMacroStep = nil }
                                        model.removeMacroStep(step.id)
                                    } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                                .padding(7)
                                .background(chosenMacroStep == step.id ? purple.opacity(0.11) : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 9))
                            }
                            Button {
                                model.addMacroStep()
                                chosenMacroStep = model.editingMacro.steps.last?.id
                            } label: { Label("클릭 추가", systemImage: "plus") }
                                .disabled(model.macroRunning || model.editingMacro.steps.count >= 32)
                            Divider()
                            HStack(spacing: 8) {
                                Text("반복").font(.caption).frame(width: 42, alignment: .leading)
                                TextField("횟수", value: $model.editingMacro.repeatCount, format: .number)
                                    .frame(width: 66)
                                    .disabled(model.editingMacro.repeatForever)
                                Text("회").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Toggle("무한 반복", isOn: $model.editingMacro.repeatForever)
                                    .toggleStyle(.checkbox)
                            }
                            HStack(spacing: 8) {
                                Text("주기").font(.caption).frame(width: 42, alignment: .leading)
                                TextField("주기", value: $model.editingMacro.intervalMs, format: .number)
                                    .frame(width: 66)
                                Text("ms").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            Toggle("다른 Mac 창에서도 계속 클릭", isOn: $model.editingMacro.continueInBackground)
                                .toggleStyle(.checkbox)
                            Text("Android 안에서 대상 앱을 벗어나면 중지됩니다. 게임의 백그라운드 동작은 게임마다 다릅니다.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("좌표 기준 \(model.editingMacro.referenceWidth) × \(model.editingMacro.referenceHeight)px")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                Button("매크로 저장") { model.saveMacro() }
                                    .buttonStyle(.borderedProminent).tint(purple)
                                    .disabled(model.macroRunning || !model.hasUnsavedMacro || model.editingMacro.steps.isEmpty)
                                if model.macros.contains(where: { $0.id == model.editingMacro.id }) {
                                    Button("삭제", role: .destructive) { confirmMacroDelete = true }
                                        .disabled(model.macroRunning)
                                }
                            }
                        }
                        .disabled(model.macroRunning)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .confirmationDialog("이 매크로를 삭제할까요?", isPresented: $confirmMacroDelete) {
            Button("삭제", role: .destructive) { model.deleteMacro(); chosenMacroStep = nil }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.busy { ProgressView().controlSize(.small).frame(width: 14, height: 14) }
            else { Image(systemName: model.status.contains("실패") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundColor(model.status.contains("실패") ? .red : .green) }
            Text(model.status).font(.system(size: 11)).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).frame(minHeight: 42)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func heading(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(purple)
                .frame(width: 30, height: 30)
                .background(purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private func infoPill(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    }
    private func preset(_ title: String, scale: Double) -> some View {
        Button(title) { model.setResolutionScale(scale) }
            .buttonStyle(.bordered).disabled(model.displayInfo == nil)
    }
}

private struct SurfaceCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(19).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.primary.opacity(0.06)))
    }
}

private struct QuickAction: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.52)
    }
}

private struct PhonePreview: View {
    let image: NSImage?
    let mappings: [KeyMapping]
    let selectedID: UUID?
    let width: Int
    let height: Int
    let onTap: (Double, Double) -> Void
    private var size: CGSize {
        let factor = min(230 / CGFloat(max(1, width)), 340 / CGFloat(max(1, height)))
        return CGSize(width: CGFloat(max(1, width)) * factor, height: CGFloat(max(1, height)) * factor)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = image {
                Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
            } else {
                LinearGradient(colors: [Color.indigo.opacity(0.25), Color.blue.opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 9) {
                    Image(systemName: "iphone.gen3").font(.system(size: 34, weight: .ultraLight))
                    Text("게임 화면을 가져오세요").font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .frame(width: size.width, height: size.height)
            }
            ForEach(mappings) { mapping in
                Text(mapping.key.isEmpty ? "•" : mapping.key.uppercased())
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(selectedID == mapping.id ? Color.orange : Color.indigo, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    .position(x: CGFloat(mapping.x) / CGFloat(max(1, width)) * size.width,
                              y: CGFloat(mapping.y) / CGFloat(max(1, height)) * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.14)))
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            if image != nil { onTap(value.location.x / size.width, value.location.y / size.height) }
        })
    }
}
