import SwiftUI
import UIKit

/// 메인 화면 (P4): 위는 상태와 녹화·송출 버튼, 가운데는 프리뷰, 옆(창이 좁으면 아래)은 장면·소스·오디오
struct ContentView: View {
    @ObservedObject private var core = Core.shared
    @ObservedObject private var outputs = Outputs.shared
    @ObservedObject private var model = SceneModel.shared
    @StateObject private var diagnostics = Diagnostics()
    @AppStorage("showDiagnostics") private var showDiagnostics = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            layout(geometry.size)
                // 가로·세로를 돌리면 배치가 바뀐다 (CI가 이 줄로 방향 시험을 확인한다)
                .onChange(of: geometry.size, initial: true) { _, size in
                    appLog("layout: \(Int(size.width))x\(Int(size.height)) (\(size.width >= 900 ? "side column" : "stacked"))")
                }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            appLog("content appeared")
            // 방송 중 화면 자동 잠금을 막는다 (계획 5.4)
            UIApplication.shared.isIdleTimerDisabled = true
            ScreenOrientation.applyLaunchArgument()
        }
        .onChange(of: scenePhase) { _, phase in
            // 백그라운드로 가거나 끝나기 전에 씬 구성을 저장한다
            if phase != .active && core.isRunning { model.saveNow() }
        }
    }

    /// 창이 넓으면(가로 화면) 옆 칸을 오른쪽에, 좁으면(세로 화면·창 모드) 아래에 둔다
    @ViewBuilder
    private func layout(_ size: CGSize) -> some View {
        if size.width >= 900 {
            HStack(spacing: 0) {
                mainColumn
                Divider()
                SideColumn(model: model, core: core).frame(width: 340)
            }
        } else {
            VStack(spacing: 0) {
                mainColumn
                Divider()
                SideColumn(model: model, core: core).frame(height: size.height * 0.45)
            }
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            TopBar(outputs: outputs, showDiagnostics: $showDiagnostics)
            PreviewArea(core: core, model: model)
                .overlay(alignment: .topLeading) {
                    if showDiagnostics {
                        DiagnosticsOverlay(diagnostics: diagnostics, outputs: outputs)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

// MARK: - 위쪽 막대

struct TopBar: View {
    @ObservedObject var outputs: Outputs
    @Binding var showDiagnostics: Bool
    @AppStorage(AppSettings.previewEnabled) private var previewEnabled = true

    var body: some View {
        HStack(spacing: 10) {
            if outputs.stats.recording {
                StatusChip(text: "REC " + formatClock(outputs.stats.recording_seconds), color: .red)
            }
            if outputs.replayNotice != nil {
                StatusChip(text: "리플레이 저장됨", color: .green)
            } else if outputs.stats.replay_active {
                StatusChip(text: "REPLAY", color: .green)
            }
            if outputs.stats.stream_reconnecting {
                StatusChip(text: "재연결 중", color: .orange)
            } else if outputs.stats.streaming {
                StatusChip(
                    text: "LIVE " + formatClock(outputs.stats.streaming_seconds)
                        + String(format: "  %.0f kbps", outputs.streamKbps),
                    color: .blue)
            }

            Spacer(minLength: 0)

            OutputControls(outputs: outputs)

            Button {
                previewEnabled.toggle()
            } label: {
                Image(systemName: previewEnabled ? "eye" : "eye.slash")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(previewEnabled ? "미리보기 끄기" : "미리보기 켜기")

            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: showDiagnostics ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.08))
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color, in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

func formatClock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

// MARK: - 프리뷰와 터치 편집

/// 프리뷰. 누르면 그 자리의 소스를 고르고, 끌면 옮기고, 두 손가락으로 벌리거나 오므리면 크기를 바꾼다.
struct PreviewArea: View {
    @ObservedObject var core: Core
    @ObservedObject var model: SceneModel

    @State private var dragging = false
    @State private var lastTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @AppStorage(AppSettings.previewEnabled) private var previewEnabled = true

    var body: some View {
        ZStack {
            Color.black

            if core.isRunning && !previewEnabled {
                // 프리뷰 디스플레이를 없애 GPU가 프리뷰를 그리고 화면에 내보내는 일을 멈춘다
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash").font(.system(size: 36))
                    Text("미리보기 꺼짐").font(.headline)
                    Text("송출과 녹화는 그대로 계속됩니다.").font(.footnote).foregroundStyle(.secondary)
                    Button("미리보기 켜기") { previewEnabled = true }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
            } else if core.isRunning {
                PreviewView()
                    .aspectRatio(CGFloat(core.width) / CGFloat(core.height), contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            interaction(viewToCanvas: CGFloat(core.width) / max(geometry.size.width, 1))
                        }
                    }
            } else {
                Text(core.failed ? "libobs를 시작하지 못했습니다. 로그를 확인하세요." : "libobs 시작 중…")
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func interaction(viewToCanvas scale: CGFloat) -> some View {
        ZStack {
            if model.selectionBox.count == 4 {
                Path { path in
                    path.addLines(model.selectionBox.map { CGPoint(x: $0.x / scale, y: $0.y / scale) })
                    path.closeSubpath()
                }
                .stroke(model.selectedItem?.locked == true ? Color.gray : Color.yellow, lineWidth: 2)
                .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .gesture(drag(scale))
                .simultaneousGesture(magnify(scale))
        }
    }

    private func drag(_ scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    lastTranslation = .zero

                    // 고른 소스 위에서 시작하면 그대로 끌고, 아니면 그 자리의 소스를 고른다 (빈 곳이면 선택 해제)
                    let point = CGPoint(x: value.startLocation.x * scale, y: value.startLocation.y * scale)
                    if !Self.contains(model.selectionBox, point) {
                        model.select(model.item(at: point))
                    }
                }

                let delta = CGSize(
                    width: (value.translation.width - lastTranslation.width) * scale,
                    height: (value.translation.height - lastTranslation.height) * scale)
                lastTranslation = value.translation
                if delta != .zero { model.translateSelection(by: delta) }
            }
            .onEnded { value in
                dragging = false
                if value.translation != .zero { model.transformEnded() }
            }
    }

    private func magnify(_ scale: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let factor = value.magnification / lastMagnification
                lastMagnification = value.magnification
                let center = CGPoint(x: value.startLocation.x * scale, y: value.startLocation.y * scale)
                model.scaleSelection(by: factor, around: center)
            }
            .onEnded { _ in
                lastMagnification = 1
                model.transformEnded()
            }
    }

    /// 볼록 사각형(선택 상자) 안의 점인지
    static func contains(_ box: [CGPoint], _ point: CGPoint) -> Bool {
        guard box.count == 4 else { return false }
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = box[i]
            let b = box[(i + 1) % 4]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross != 0 {
                if sign == 0 {
                    sign = cross
                } else if (sign > 0) != (cross > 0) {
                    return false
                }
            }
        }
        return true
    }
}

// MARK: - 옆 칸: 장면·소스·오디오, 또는 채팅 패널

struct SideColumn: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var core: Core
    @AppStorage("sideColumnTab") private var tab = "sources"

    var body: some View {
        VStack(spacing: 0) {
            Picker("옆 칸", selection: $tab) {
                Text("장면·소스").tag("sources")
                Text("채팅").tag("chat")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if tab == "chat" {
                ChatPanelView(feed: ChatFeed.shared) { tab = "sources" }
            } else {
                Sidebar(model: model, core: core)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

struct Sidebar: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var core: Core

    private struct EditedSource: Identifiable {
        let name: String
        var id: String { name }
    }

    private enum Renaming {
        case scene(String)
        case source(SceneItem)
    }

    @State private var addingSource = false
    @State private var sourceToEdit: EditedSource?
    @State private var filtersToEdit: EditedSource?
    @State private var pendingEdit: String?
    @State private var renaming: Renaming?
    @State private var renameText = ""

    var body: some View {
        List {
            Section("장면") {
                ForEach(model.scenes, id: \.self) { scene in
                    Button {
                        model.switchTo(scene)
                    } label: {
                        HStack {
                            Text(scene)
                            Spacer()
                            if scene == model.currentScene {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    // 목록 안 버튼 글자가 링크처럼 파랗게 나오지 않게
                    .tint(.primary)
                    .contextMenu {
                        Button("이름 바꾸기…") { startRenaming(.scene(scene), current: scene) }
                        Button("위로") { model.moveScene(scene, by: -1) }
                        Button("아래로") { model.moveScene(scene, by: 1) }
                        Button("삭제", role: .destructive) { model.removeScene(scene) }
                            .disabled(model.scenes.count < 2)
                    }
                }
                Button {
                    model.addScene()
                } label: {
                    Label("장면 추가", systemImage: "plus")
                }
            }

            Section("소스") {
                ForEach(model.items) { item in
                    SourceRow(
                        item: item, selected: item.id == model.selection, model: model,
                        editProperties: { sourceToEdit = EditedSource(name: item.name) },
                        editFilters: { filtersToEdit = EditedSource(name: item.name) },
                        rename: { startRenaming(.source(item), current: item.name) })
                }
                Button {
                    addingSource = true
                } label: {
                    Label("소스 추가", systemImage: "plus")
                }
            }

            Section {
                AudioInputRow(core: core) {
                    filtersToEdit = EditedSource(name: String(cString: core_audio_input_name()))
                }
            } header: {
                HStack {
                    Text("오디오")
                    Spacer()
                    audioFiltersMenu
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(
            isPresented: $addingSource,
            onDismiss: {
                // 소스를 넣었으면 바로 속성을 연다
                if let name = pendingEdit {
                    pendingEdit = nil
                    sourceToEdit = EditedSource(name: name)
                }
            }
        ) {
            AddSourceSheet(model: model) { pendingEdit = $0 }
        }
        .sheet(item: $sourceToEdit) { source in
            NavigationStack {
                SourcePropertiesView(sourceName: source.name, showsFilters: true) { model.setNeedsSave() }
                    .navigationTitle(source.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("완료") { sourceToEdit = nil }
                        }
                    }
            }
        }
        .sheet(item: $filtersToEdit) { source in
            NavigationStack {
                FiltersView(sourceName: source.name) { model.setNeedsSave() }
                    .navigationTitle("\(source.name) 필터")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("완료") { filtersToEdit = nil }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autotestSheet)) { note in
            let sheet = note.object as? String ?? ""
            addingSource = sheet == "add source"
            sourceToEdit = sheet.hasPrefix("properties:") ? EditedSource(name: String(sheet.dropFirst(11))) : nil
        }
        .alert(
            "이름 바꾸기",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("이름", text: $renameText)
            Button("취소", role: .cancel) { renaming = nil }
            Button("확인") { finishRenaming() }
        } message: {
            Text("같은 이름이 이미 있으면 바뀌지 않습니다.")
        }
    }

    /// 오디오 머리글 옆: 오디오 입력과 이 장면의 소리 있는 소스 중 골라 필터를 연다
    private var audioFiltersMenu: some View {
        let audioInput = String(cString: core_audio_input_name())
        var seen: Set<String> = [audioInput]
        let sources = model.items.filter { $0.audio && seen.insert($0.name).inserted }.map(\.name)

        return Menu {
            Button(audioInput.isEmpty ? "오디오 입력" : audioInput, systemImage: "mic") {
                filtersToEdit = EditedSource(name: audioInput)
            }
            .disabled(audioInput.isEmpty)
            if !sources.isEmpty {
                Section("이 장면의 소스") {
                    ForEach(sources, id: \.self) { name in
                        Button(name) { filtersToEdit = EditedSource(name: name) }
                    }
                }
            }
        } label: {
            Label("오디오 필터", systemImage: "waveform")
                .font(.footnote.weight(.semibold))
        }
        .textCase(nil)
    }

    private func startRenaming(_ target: Renaming, current: String) {
        renameText = current
        renaming = target
    }

    private func finishRenaming() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        switch renaming {
        case .scene(let scene): model.renameScene(scene, to: name)
        case .source(let item): model.renameSource(item, to: name)
        case nil: break
        }
        renaming = nil
    }
}

struct SourceRow: View {
    let item: SceneItem
    let selected: Bool
    let model: SceneModel
    let editProperties: () -> Void
    let editFilters: () -> Void
    let rename: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.setVisible(item, !item.visible)
            } label: {
                Image(systemName: item.visible ? "eye" : "eye.slash")
                    .foregroundStyle(item.visible ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)

            Text(item.name)
                .lineLimit(1)
                .foregroundStyle(item.visible ? .primary : .secondary)

            Spacer(minLength: 0)

            if item.locked {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }

            Menu {
                Button("속성…", systemImage: "slider.horizontal.3", action: editProperties)
                if item.audio {
                    Button("오디오 필터…", systemImage: "waveform", action: editFilters)
                }
                if item.type == "ios_media_source" {
                    Divider()
                    Button("재생/일시정지", systemImage: "playpause") { _ = core_source_media(item.name, 0) }
                    Button("처음부터", systemImage: "backward.end") { _ = core_source_media(item.name, 1) }
                    Button("정지", systemImage: "stop") { _ = core_source_media(item.name, 2) }
                }
                Button("이름 바꾸기…", systemImage: "pencil", action: rename)
                Divider()
                if item.video {
                    Button("화면에 맞추기", systemImage: "arrow.up.left.and.arrow.down.right") { model.fit(item) }
                    Button("원래 크기", systemImage: "arrow.counterclockwise") { model.resetTransform(item) }
                }
                Button(item.locked ? "잠금 해제" : "잠금", systemImage: item.locked ? "lock.open" : "lock") {
                    model.setLocked(item, !item.locked)
                }
                Divider()
                Button("위로", systemImage: "chevron.up") { model.order(item, .up) }
                Button("아래로", systemImage: "chevron.down") { model.order(item, .down) }
                Button("맨 위로", systemImage: "chevron.up.2") { model.order(item, .top) }
                Button("맨 아래로", systemImage: "chevron.down.2") { model.order(item, .bottom) }
                Divider()
                Button("삭제", systemImage: "trash", role: .destructive) { model.remove(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(item.id) }
        .listRowBackground(selected ? Color.accentColor.opacity(0.25) : nil)
    }
}

struct AddSourceSheet: View {
    let model: SceneModel
    let added: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var types: [SourceType] = []

    var body: some View {
        NavigationStack {
            List(types) { type in
                Button {
                    if let name = model.addSource(type: type) { added(name) }
                    dismiss()
                } label: {
                    Label(type.displayName, systemImage: type.systemImage)
                }
            }
            .navigationTitle("소스 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
            .onAppear { types = model.sourceTypes }
        }
    }
}

/// 전역 오디오 입력: 장치, 음소거, 볼륨
struct AudioInputRow: View {
    @ObservedObject var core: Core
    var editFilters: () -> Void = {}

    @State private var volumeDB: Double = 0
    @State private var muted = false

    private var sourceName: String { String(cString: core_audio_input_name()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Picker(
                        "입력 장치",
                        selection: Binding(
                            get: { core.currentAudioInput },
                            set: { core.select(CORE_DEVICE_AUDIO_INPUT, $0) })
                    ) {
                        ForEach(core.audioInputs) { device in
                            Text(device.id.isEmpty ? "시스템 기본" : deviceLabel(device)).tag(device.id)
                                .selectionDisabled(!device.available)
                        }
                    }
                } label: {
                    Label(currentDeviceName, systemImage: "mic")
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button(action: editFilters) {
                    Image(systemName: "waveform")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("오디오 필터")

                Button {
                    muted.toggle()
                    core_source_set_muted(sourceName, muted)
                    SceneModel.shared.setNeedsSave()
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(muted ? Color.red : Color.accentColor)
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Slider(value: $volumeDB, in: -60...0) { editing in
                    guard !editing else { return }
                    core_source_set_volume(sourceName, volumeDB <= -60 ? 0 : Float(pow(10, volumeDB / 20)))
                    SceneModel.shared.setNeedsSave()
                }
                Text(volumeDB <= -60 ? "-∞ dB" : String(format: "%.0f dB", volumeDB))
                    .font(.footnote.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .onAppear(perform: load)
        .onChange(of: core.isRunning) { _, _ in load() }
    }

    private var currentDeviceName: String {
        if core.currentAudioInput.isEmpty { return "시스템 기본" }
        guard let device = core.audioInputs.first(where: { $0.id == core.currentAudioInput }) else {
            return core.currentAudioInput
        }
        return device.available ? device.name : "\(device.name) (연결 끊김, 시스템 기본 사용 중)"
    }

    private func deviceLabel(_ device: Device) -> String {
        device.available ? device.name : "\(device.name) (연결 끊김)"
    }

    private func load() {
        let multiplier = core_source_volume(sourceName)
        volumeDB = multiplier > 0 ? max(-60, 20 * log10(Double(multiplier))) : -60
        muted = core_source_muted(sourceName)
    }
}

// MARK: - 화면 방향과 화면 시험 (CI)

/// CI 시뮬레이터에는 기기를 돌리는 명령이 없어, 앱이 창의 방향을 바꿔 달라고 한다 (UIRequiresFullScreen이라 받아 준다).
/// 화면 배치는 창 크기만 보므로 기기를 돌린 것과 같다. 카메라 방향은 기기 센서를 따르므로 실기기에서 본다.
enum ScreenOrientation {
    /// `-orientation landscape|portrait`: 그 방향으로 띄운다
    @MainActor
    static func applyLaunchArgument() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-orientation"), index + 1 < args.count else { return }
        request(landscape: args[index + 1] == "landscape")
    }

    @MainActor
    static func request(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            appLog("orientation: no window scene")
            return
        }
        appLog("orientation: requesting \(landscape ? "landscape" : "portrait")")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { error in
            appLog("orientation: request failed: \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    /// 화면 시험이 시트를 연다: "settings", "add source", "properties:<소스 이름>". 그 밖의 값(nil)이면 닫는다
    static let autotestSheet = Notification.Name("autotestSheet")
}

/// CI (`-autotest-ui`, 다시 띄운 실행): 세로로 뜬 화면을 가로로 돌리고, 가로에서 설정·소스 추가·소스 속성 시트를 하나씩 연 뒤
/// 다시 세로로 돌린다. 화면마다 "ui autotest: shot <이름>"을 남기면 CI가 그 줄을 보고 스크린숏을 찍는다.
@MainActor
enum UIAutotest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-autotest-ui") else { return }
        Task { await run() }
    }

    private static func run() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        // 돌리거나 시트를 연 애니메이션이 끝나게 기다렸다가 알리고, 찍을 시간을 둔다
        func shot(_ name: String) async {
            await pause(2)
            appLog("ui autotest: shot \(name)")
            await pause(3)
        }
        func sheet(_ sheet: String, shot name: String) async {
            NotificationCenter.default.post(name: .autotestSheet, object: sheet)
            await shot(name)
            NotificationCenter.default.post(name: .autotestSheet, object: nil)
            await pause(1)
        }

        appLog("ui autotest: start")
        UserDefaults.standard.set("sources", forKey: "sideColumnTab")
        await shot("1-portrait")

        ScreenOrientation.request(landscape: true)
        await shot("2-landscape")
        await sheet("settings", shot: "3-settings")
        await sheet("add source", shot: "4-add-source")
        // 채팅 소스(상태 줄이 있는 속성)가 있으면 그것을, 없으면 첫 소스
        let items = SceneModel.shared.items
        if let item = items.last(where: { $0.type == "ios_chat_source" }) ?? items.first {
            await sheet("properties:\(item.name)", shot: "5-properties")
        }
        UserDefaults.standard.set("chat", forKey: "sideColumnTab")
        await shot("6-chat")

        UserDefaults.standard.set("sources", forKey: "sideColumnTab")
        ScreenOrientation.request(landscape: false)
        await shot("7-portrait")
        appLog("ui autotest: done")
    }
}
