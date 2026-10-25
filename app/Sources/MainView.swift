import SwiftUI
import UIKit

/// 메인 화면 (P4): PC OBS처럼 위는 프리뷰, 그 아래 장면·소스·오디오·제어 독, 오른쪽 끝은 채팅 패널, 맨 아래는 상태 줄.
/// 창이 좁으면(세로 화면·창 모드) 프리뷰를 맨 위 전체 폭에 두고, 그 아래에 독(2×2)과 채팅을 나란히 둔다.
struct ContentView: View {
    @ObservedObject private var core = Core.shared
    @ObservedObject private var outputs = Outputs.shared
    @ObservedObject private var model = SceneModel.shared
    @StateObject private var diagnostics = Diagnostics()
    @StateObject private var sheets = StudioSheets()
    @AppStorage("showDiagnostics") private var showDiagnostics = true
    @AppStorage(AppSettings.chatPanelShown) private var chatShown = true
    @AppStorage(AppSettings.statusBarShown) private var statusBarShown = true
    @AppStorage(AppSettings.developerMode) private var developerMode = false
    @AppStorage(AppSettings.glassUI) private var glassUI = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            screen(geometry.size)
                // 가로·세로를 돌리면 배치가 바뀐다 (CI가 이 줄로 방향 시험을 확인한다)
                .onChange(of: geometry.size, initial: true) { _, size in
                    ScreenOrientation.windowSize = size
                    appLog(
                        "layout: \(Int(size.width))x\(Int(size.height)) "
                            + "(\(StudioLayout.isWide(size) ? "side column" : "stacked")\(glass ? ", glass" : ""))")
                }
                .onChange(of: glass) { _, glass in appLog("screen: \(glass ? "Liquid Glass" : "classic")") }
        }
        // 상태 표시줄을 보이면 그 높이만큼 안전 영역이 생겨 화면은 그 아래부터 그리고, 그 자리는 이 검정만 남는다
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(!statusBarShown)
        .onChange(of: statusBarShown, initial: true) { _, shown in
            appLog("status bar: \(shown ? "shown" : "hidden")")
        }
        .preferredColorScheme(.dark)
        .modifier(StudioSheetsModifier(sheets: sheets, model: model, outputs: outputs))
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

    /// Liquid Glass 화면 (개발자 옵션, iOS 26+)
    private var glass: Bool {
        guard #available(iOS 26, *) else { return false }
        return developerMode && glassUI
    }

    @ViewBuilder
    private func screen(_ size: CGSize) -> some View {
        if glass {
            if #available(iOS 26, *) {
                GlassStudio(
                    core: core, outputs: outputs, model: model, diagnostics: diagnostics, sheets: sheets, size: size,
                    showDiagnostics: $showDiagnostics, chatShown: $chatShown)
            }
        } else {
            studio(wide: StudioLayout.isWide(size))
        }
    }

    /// 넓은 배치와 좁은 배치를 StudioLayout 하나가 계산한다: 돌려도 안의 뷰는 그대로 두고 자리만 옮긴다.
    /// 배치마다 다른 스택을 쓰면 돌릴 때마다 화면 전체가 새로 만들어져 프리뷰 디스플레이를 다시 만들고 열린 시트가 닫힌다.
    private func studio(wide: Bool) -> some View {
        StudioLayout(wide: wide, gap: 1 / displayScale) {
            PreviewArea(core: core, model: model)
                .overlay(alignment: .topLeading) {
                    if showDiagnostics {
                        DiagnosticsOverlay(diagnostics: diagnostics, outputs: outputs)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .studioPart(.preview)
            ScenesDock(model: model, sheets: sheets)
                .studioPart(.scenes)
            SourcesDock(model: model, sheets: sheets)
                .studioPart(.sources)
            AudioDock(core: core, sheets: sheets)
                .studioPart(.audio)
            ControlsDock(outputs: outputs, sheets: sheets, showDiagnostics: $showDiagnostics, chatShown: $chatShown)
                .studioPart(.controls)
            if chatShown {
                Dock("채팅") {
                    ChatPanelView(feed: ChatFeed.shared) { chatShown = false }
                }
                .studioPart(.chat)
            }
            StatusBar(outputs: outputs, diagnostics: diagnostics)
                .studioPart(.status)
        }
        // 칸 사이 틈으로 보이는 선 (홈 표시줄 자리까지 칠하지 않게)
        .background(Color(white: 0.22), ignoresSafeAreaEdges: [])
    }
}

// MARK: - 배치

enum StudioPart {
    case preview, scenes, sources, audio, controls, chat, status
}

private struct StudioPartKey: LayoutValueKey {
    static let defaultValue = StudioPart.preview
}

extension View {
    func studioPart(_ part: StudioPart) -> some View {
        layoutValue(key: StudioPartKey.self, value: part)
    }
}

/// 넓으면: 채팅이 오른쪽 위에서 아래까지, 그 왼쪽은 프리뷰 / 독 네 개 한 줄 / 상태 줄.
/// 좁으면: 프리뷰가 맨 위 전체 폭, 그 아래 독(폭이 되면 한 줄, 아니면 2×2)과 채팅, 맨 아래 상태 줄.
/// 채팅을 숨기면 그 자리를 다른 칸이 쓴다. 칸 사이는 gap만큼 띄워 뒤 배경이 선으로 보이게 한다.
struct StudioLayout: Layout {
    let wide: Bool
    let gap: CGFloat

    static let statusHeight: CGFloat = 28

    static func isWide(_ size: CGSize) -> Bool {
        size.width >= 900 && size.width > size.height
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = partFrames(in: bounds.size, chat: subviews.contains { $0[StudioPartKey.self] == .chat })
        for subview in subviews {
            let frame = frames[subview[StudioPartKey.self]] ?? .zero
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func partFrames(in size: CGSize, chat: Bool) -> [StudioPart: CGRect] {
        let status = Self.statusHeight
        var frames: [StudioPart: CGRect] = [:]
        if wide {
            let chatWidth = chat ? min(380, max(280, size.width * 0.26)).rounded() : 0
            let mainWidth = chat ? size.width - chatWidth - gap : size.width
            let dockHeight = min(330, max(220, size.height * 0.34)).rounded()
            let previewHeight = max(0, size.height - dockHeight - status - 2 * gap)
            frames[.preview] = CGRect(x: 0, y: 0, width: mainWidth, height: previewHeight)
            placeDocks(
                in: CGRect(x: 0, y: previewHeight + gap, width: mainWidth, height: dockHeight), columns: 4,
                into: &frames)
            frames[.status] = CGRect(x: 0, y: size.height - status, width: mainWidth, height: status)
            if chat { frames[.chat] = CGRect(x: mainWidth + gap, y: 0, width: chatWidth, height: size.height) }
        } else {
            let previewHeight = min(size.width * 9 / 16, size.height * 0.45).rounded()
            let top = previewHeight + gap
            let areaHeight = max(0, size.height - top - gap - status)
            let chatWidth = chat ? min(360, size.width * 0.4).rounded() : 0
            let dockWidth = chat ? size.width - chatWidth - gap : size.width
            frames[.preview] = CGRect(x: 0, y: 0, width: size.width, height: previewHeight)
            placeDocks(
                in: CGRect(x: 0, y: top, width: dockWidth, height: areaHeight), columns: dockWidth >= 760 ? 4 : 2,
                into: &frames)
            frames[.status] = CGRect(x: 0, y: size.height - status, width: size.width, height: status)
            if chat { frames[.chat] = CGRect(x: dockWidth + gap, y: top, width: chatWidth, height: areaHeight) }
        }
        return frames
    }

    /// 장면·소스·오디오·제어. 한 줄이면 폭을 24:34:24:18로, 두 줄이면 2×2
    private func placeDocks(in rect: CGRect, columns: Int, into frames: inout [StudioPart: CGRect]) {
        let parts: [StudioPart] = [.scenes, .sources, .audio, .controls]
        if columns == 4 {
            let weights: [CGFloat] = [0.24, 0.34, 0.24, 0.18]
            let usable = rect.width - 3 * gap
            var x = rect.minX
            for (index, part) in parts.enumerated() {
                let width = index == parts.count - 1 ? rect.maxX - x : (usable * weights[index]).rounded()
                frames[part] = CGRect(x: x, y: rect.minY, width: width, height: rect.height)
                x += width + gap
            }
        } else {
            let width = ((rect.width - gap) / 2).rounded()
            let height = ((rect.height - gap) / 2).rounded()
            for (index, part) in parts.enumerated() {
                let column = index % 2
                let row = index / 2
                frames[part] = CGRect(
                    x: rect.minX + CGFloat(column) * (width + gap), y: rect.minY + CGFloat(row) * (height + gap),
                    width: column == 0 ? width : rect.width - width - gap,
                    height: row == 0 ? height : rect.height - height - gap)
            }
        }
    }
}

/// 독 하나: 제목 줄, 내용, (있으면) 아래 도구 줄. PC OBS의 독처럼
struct Dock<Content: View, Toolbar: View>: View {
    let title: String
    let content: Content
    let toolbar: Toolbar
    @Environment(\.dockChrome) private var chrome

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder toolbar: () -> Toolbar) {
        self.title = title
        self.content = content()
        self.toolbar = toolbar()
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(chrome == .glass ? Color.clear : Color(white: 0.14))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if Toolbar.self != EmptyView.self {
                HStack(spacing: 0) { toolbar }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 36)
                    .background(chrome == .glass ? Color.clear : Color(white: 0.12))
            }
        }
        .background(chrome == .glass ? Color.clear : Color(white: 0.09))
        .clipped()
    }
}

extension Dock where Toolbar == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, toolbar: { EmptyView() })
    }
}

/// 독 아래 도구 줄의 아이콘 버튼
struct DockButton: View {
    let label: String
    let icon: String
    let action: () -> Void

    init(_ label: String, _ icon: String, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 38, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - 시트

/// 여러 독에서 여는 시트와 이름 바꾸기. 화면 맨 위 한 곳에 붙여서 돌려도 닫히지 않는다 (메인 스레드에서만 쓴다)
final class StudioSheets: ObservableObject {
    struct Source: Identifiable {
        let name: String
        var id: String { name }
    }

    enum Renaming {
        case scene(String)
        case source(SceneItem)
    }

    @Published var settings = false
    /// 설정을 열 때 보일 페이지 (nil이면 마지막으로 본 페이지)
    var settingsPage: SettingsPage?
    @Published var addingSource = false
    @Published var properties: Source?
    @Published var filters: Source?
    @Published var renaming: Renaming?
    @Published var renameText = ""
    /// 소스 추가 시트에서 넣은 소스. 시트가 닫히면 바로 그 속성을 연다
    var added: String?

    func openSettings(_ page: SettingsPage? = nil) {
        settingsPage = page
        settings = true
    }

    func editProperties(_ name: String) { properties = Source(name: name) }
    func editFilters(_ name: String) { filters = Source(name: name) }

    func rename(_ target: Renaming, current: String) {
        renameText = current
        renaming = target
    }
}

/// iOS 18 이상: 시트를 페이지 크기로 (설정의 왼쪽 목록과 오른쪽 내용이 나란히 보이게)
private struct PageSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}

private struct StudioSheetsModifier: ViewModifier {
    @ObservedObject var sheets: StudioSheets
    let model: SceneModel
    let outputs: Outputs

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $sheets.settings, onDismiss: { sheets.settingsPage = nil }) {
                SettingsView(core: Core.shared, outputs: outputs, initialPage: sheets.settingsPage)
                    // 왼쪽 목록이 보일 만큼 넓게
                    .modifier(PageSheetSizing())
                    // 가로·세로를 돌려도 열린 시트가 남는지 CI가 이 줄로 본다
                    .onAppear { appLog("settings sheet: shown") }
                    .onDisappear { appLog("settings sheet: closed") }
            }
            .sheet(
                isPresented: $sheets.addingSource,
                onDismiss: {
                    if let name = sheets.added {
                        sheets.added = nil
                        sheets.editProperties(name)
                    }
                }
            ) {
                AddSourceSheet(model: model) { sheets.added = $0 }
            }
            .sheet(item: $sheets.properties) { source in
                NavigationStack {
                    SourcePropertiesView(sourceName: source.name, showsFilters: true) { model.setNeedsSave() }
                        .navigationTitle(source.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("완료") { sheets.properties = nil }
                            }
                        }
                }
            }
            .sheet(item: $sheets.filters) { source in
                NavigationStack {
                    FiltersView(sourceName: source.name) { model.setNeedsSave() }
                        .navigationTitle("\(source.name) 필터")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("완료") { sheets.filters = nil }
                            }
                        }
                }
            }
            .alert(
                "이름 바꾸기",
                isPresented: Binding(get: { sheets.renaming != nil }, set: { if !$0 { sheets.renaming = nil } })
            ) {
                TextField("이름", text: $sheets.renameText)
                Button("취소", role: .cancel) { sheets.renaming = nil }
                Button("확인") { finishRenaming() }
            } message: {
                Text("같은 이름이 이미 있으면 바뀌지 않습니다.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .autotestSheet)) { note in
                let sheet = note.object as? String ?? ""
                sheets.settings = sheet == "settings"
                sheets.addingSource = sheet == "add source"
                sheets.properties = sheet.hasPrefix("properties:") ? .init(name: String(sheet.dropFirst(11))) : nil
            }
            // 메뉴 막대·키보드 단축키 (Commands.swift)
            .onReceive(NotificationCenter.default.publisher(for: .studioCommand)) { note in
                switch (note.object as? String).flatMap(StudioCommand.init(rawValue:)) {
                case .settings: sheets.openSettings()
                case .addSource: sheets.addingSource = true
                case .properties: if let item = model.selectedItem { sheets.editProperties(item.name) }
                case .toggleStream: if !outputs.toggleStreaming() { sheets.openSettings(.stream) }
                case nil: break
                }
            }
    }

    private func finishRenaming() {
        let name = sheets.renameText.trimmingCharacters(in: .whitespaces)
        switch sheets.renaming {
        case .scene(let scene): model.renameScene(scene, to: name)
        case .source(let item): model.renameSource(item, to: name)
        case nil: break
        }
        sheets.renaming = nil
    }
}

// MARK: - 상태 줄

/// 맨 아래 줄 (PC OBS의 상태 표시줄): 송출·녹화·리플레이 상태, 송출 비트레이트와 버린 프레임, 렌더 fps, 발열
struct StatusBar: View {
    @ObservedObject var outputs: Outputs
    @ObservedObject var diagnostics: Diagnostics
    @Environment(\.dockChrome) private var chrome

    var body: some View {
        let stats = outputs.stats

        HStack(spacing: 10) {
            if stats.stream_reconnecting {
                StatusChip(text: "재연결 중", color: .orange)
            } else if stats.streaming {
                StatusChip(text: "LIVE " + formatClock(stats.streaming_seconds), color: .blue)
            }
            if stats.recording {
                StatusChip(text: "REC " + formatClock(stats.recording_seconds), color: .red)
            }
            if outputs.replayNotice != nil {
                StatusChip(text: "리플레이 저장됨", color: .green)
            } else if stats.replay_active {
                StatusChip(text: "REPLAY", color: .green)
            }
            if !stats.streaming && !stats.stream_reconnecting && !stats.recording && !stats.replay_active {
                Text(outputs.streamPreparing ? "방송 준비 중…" : "대기 중")
            }

            Spacer(minLength: 8)

            if stats.streaming {
                Text(String(format: "%.0f kbps", outputs.streamKbps))
                Text(dropText(stats))
            }
            Text(String(format: "%.1f fps", diagnostics.stats.active_fps))
            Text("발열 \(diagnostics.thermalState)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, chrome == .glass ? 16 : 10)
        .frame(maxWidth: chrome == .glass ? nil : .infinity, maxHeight: chrome == .glass ? nil : .infinity)
        .background(chrome == .glass ? Color.clear : Color(white: 0.07))
    }

    /// 네트워크가 못 따라가 버린 프레임 (PC OBS의 "Dropped Frames")
    private func dropText(_ stats: core_output_stats) -> String {
        let total = max(stats.stream_total_frames, 1)
        return String(
            format: "버림 %d (%.1f%%)", stats.stream_dropped_frames, Double(stats.stream_dropped_frames) * 100 / Double(total))
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
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

// MARK: - 장면·소스 독

struct ScenesDock: View {
    @ObservedObject var model: SceneModel
    let sheets: StudioSheets
    @State private var removing: String?

    var body: some View {
        Dock("장면") {
            List {
                ForEach(model.scenes, id: \.self) { scene in
                    Button {
                        model.switchTo(scene)
                    } label: {
                        Text(scene)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    // 목록 안 버튼 글자가 링크처럼 파랗게 나오지 않게
                    .tint(.primary)
                    .listRowBackground(scene == model.currentScene ? Color.accentColor.opacity(0.35) : Color.clear)
                    .contextMenu {
                        Button("이름 바꾸기…") { sheets.rename(.scene(scene), current: scene) }
                        Button("위로") { model.moveScene(scene, by: -1) }
                        Button("아래로") { model.moveScene(scene, by: 1) }
                        Button("삭제", role: .destructive) { model.removeScene(scene) }
                            .disabled(model.scenes.count < 2)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } toolbar: {
            DockButton("장면 추가", "plus") { model.addScene() }
            DockButton("장면 삭제", "minus") { removing = model.currentScene }
                .disabled(model.scenes.count < 2)
            DockButton("이름 바꾸기", "pencil") {
                sheets.rename(.scene(model.currentScene), current: model.currentScene)
            }
            Spacer(minLength: 0)
            DockButton("위로", "chevron.up") { model.moveScene(model.currentScene, by: -1) }
            DockButton("아래로", "chevron.down") { model.moveScene(model.currentScene, by: 1) }
        }
        // 방송 중 잘못 눌러 지우지 않게 (PC OBS도 묻는다)
        .confirmationDialog(
            "장면 삭제", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { scene in
            Button("'\(scene)' 삭제", role: .destructive) { model.removeScene(scene) }
        }
    }
}

struct SourcesDock: View {
    @ObservedObject var model: SceneModel
    let sheets: StudioSheets
    @State private var removing: SceneItem?

    var body: some View {
        let selected = model.selectedItem

        Dock("소스") {
            List {
                ForEach(model.items) { item in
                    SourceRow(
                        item: item, selected: item.id == model.selection, model: model,
                        editProperties: { sheets.editProperties(item.name) },
                        editFilters: { sheets.editFilters(item.name) },
                        rename: { sheets.rename(.source(item), current: item.name) })
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.items.isEmpty {
                    Text("＋로 소스를 추가하세요").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } toolbar: {
            DockButton("소스 추가", "plus") { sheets.addingSource = true }
            DockButton("소스 삭제", "minus") { removing = selected }
                .disabled(selected == nil)
            DockButton("속성", "gearshape") {
                if let selected { sheets.editProperties(selected.name) }
            }
            .disabled(selected == nil)
            Spacer(minLength: 0)
            DockButton("위로", "chevron.up") {
                if let selected { model.order(selected, .up) }
            }
            .disabled(selected == nil)
            DockButton("아래로", "chevron.down") {
                if let selected { model.order(selected, .down) }
            }
            .disabled(selected == nil)
        }
        .confirmationDialog(
            "소스 삭제", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { item in
            Button("'\(item.name)' 삭제", role: .destructive) { model.remove(item) }
        }
    }
}

// MARK: - 오디오 독

/// 전역 오디오 입력: 장치, 미터, 볼륨, 음소거, 필터. iPadOS는 오디오 입력 경로를 하나만 쓰므로 믹서가 아니라 입력 하나다
struct AudioDock: View {
    @ObservedObject var core: Core
    let sheets: StudioSheets
    /// 미터는 따로 관찰한다 (초당 10번 바뀌는 값에 독 전체를 다시 그리지 않게)
    @State private var level = InputLevel()
    @State private var volumeDB: Double = 0
    @State private var muted = false
    @State private var editing = false

    private var name: String { String(cString: core_audio_input_name()) }

    var body: some View {
        Dock("오디오") {
            VStack(alignment: .leading, spacing: 10) {
                deviceMenu
                InputMeter(level: level, muted: muted)
                HStack(spacing: 8) {
                    Button {
                        muted.toggle()
                        core_source_set_muted(name, muted)
                        SceneModel.shared.setNeedsSave()
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(muted ? Color.red : Color.accentColor)
                            .frame(width: 30, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(muted ? "음소거 해제" : "음소거")
                    // 끄는 동안 바로 들리게 바꾼다 (불러온 값으로 바뀔 때는 쓰지 않는다)
                    Slider(value: $volumeDB, in: -60...0) { editing in
                        self.editing = editing
                        if !editing { SceneModel.shared.setNeedsSave() }
                    }
                    .onChange(of: volumeDB) { _, db in
                        guard editing else { return }
                        core_source_set_volume(name, db <= -60 ? 0 : Float(pow(10, db / 20)))
                    }
                    Text(volumeDB <= -60 ? "-∞ dB" : String(format: "%.1f dB", volumeDB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        } toolbar: {
            DockButton("오디오 필터", "waveform") { sheets.editFilters(name) }
                .disabled(name.isEmpty)
        }
        .onAppear {
            level.start()
            load()
        }
        .onDisappear { level.stop() }
        .onChange(of: core.isRunning) { _, _ in load() }
    }

    private var deviceMenu: some View {
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
                .font(.subheadline)
                .lineLimit(1)
        }
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
        let multiplier = core_source_volume(name)
        volumeDB = multiplier > 0 ? max(-60, 20 * log10(Double(multiplier))) : -60
        muted = core_source_muted(name)
    }
}

/// 오디오 입력의 최근 피크 (core_audio_input_peak를 초당 10번, 메인 스레드)
final class InputLevel: ObservableObject {
    @Published private(set) var left: Float = -.infinity
    @Published private(set) var right: Float = -.infinity
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.update() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        var left: Float = -.infinity
        var right: Float = -.infinity
        core_audio_input_peak(&left, &right)
        if left != self.left { self.left = left }
        if right != self.right { self.right = right }
    }
}

/// L/R 막대. 뒤에 구간을 흐리게 깔고(-60~-20 초록, -20~-9 노랑, -9~0 빨강, PC OBS와 같은 구간) 피크까지 밝게
struct InputMeter: View {
    @ObservedObject var level: InputLevel
    let muted: Bool

    var body: some View {
        VStack(spacing: 3) {
            bar("L", level.left)
            bar("R", level.right)
        }
        .opacity(muted ? 0.4 : 1)
    }

    private func bar(_ channel: String, _ db: Float) -> some View {
        HStack(spacing: 6) {
            Text(channel)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                let width = geometry.size.width
                let level = db.isFinite ? CGFloat(min(max((db + 60) / 60, 0), 1)) : 0
                ZStack(alignment: .leading) {
                    zones(width).opacity(0.22)
                    zones(width).mask(alignment: .leading) {
                        Rectangle().frame(width: width * level)
                    }
                }
            }
            .frame(height: 6)
        }
    }

    private func zones(_ width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.green.frame(width: width * 40 / 60)
            Color.yellow.frame(width: width * 11 / 60)
            Color.red.frame(width: width * 9 / 60)
        }
    }
}

// MARK: - 제어 독

/// 송출·녹화·리플레이와 화면 켜고 끄기, 설정 (PC OBS의 "제어" 독)
struct ControlsDock: View {
    @ObservedObject var outputs: Outputs
    let sheets: StudioSheets
    @Binding var showDiagnostics: Bool
    @Binding var chatShown: Bool
    @AppStorage(AppSettings.previewEnabled) private var previewEnabled = true

    var body: some View {
        Dock("제어") {
            ScrollView {
                VStack(spacing: 6) {
                    control(streamTitle, outputs.stats.streaming ? "stop.circle.fill" : "dot.radiowaves.left.and.right",
                            .blue, prominent: true) {
                        // 송출 서버를 정하지 않았거나 YouTube에 로그인하지 않았으면 설정의 송출 페이지를 연다
                        if !outputs.toggleStreaming() { sheets.openSettings(.stream) }
                    }
                    .disabled(outputs.streamPreparing)

                    control(recordTitle, outputs.stats.recording ? "stop.circle.fill" : "record.circle", .red,
                            prominent: true) {
                        outputs.toggleRecording()
                    }

                    if outputs.stats.replay_active {
                        HStack(spacing: 6) {
                            control("리플레이 저장", "square.and.arrow.down", .green, prominent: true) {
                                outputs.saveReplay()
                            }
                            Button {
                                outputs.toggleReplay()
                            } label: {
                                Image(systemName: "stop.fill").frame(minHeight: 22)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .accessibilityLabel("리플레이 끄기")
                        }
                    } else {
                        control("리플레이 시작", "gobackward", .green) { outputs.toggleReplay() }
                    }

                    // 화면 켜고 끄기와 설정은 작게 2×2 (가로 화면의 독 높이에 다 들어가게). 켜져 있으면 파랗게
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            smallButton("미리보기", previewEnabled ? "eye" : "eye.slash", on: previewEnabled) {
                                previewEnabled.toggle()
                            }
                            smallButton("계측", "gauge.with.dots.needle.67percent", on: showDiagnostics) {
                                showDiagnostics.toggle()
                            }
                        }
                        GridRow {
                            smallButton("채팅", "bubble.left.and.text.bubble.right", on: chatShown) { chatShown.toggle() }
                            smallButton("설정", "gearshape", on: false) { sheets.settings = true }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private var streamTitle: String { outputs.streamButtonTitle }
    private var recordTitle: String { outputs.recordButtonTitle }

    @ViewBuilder
    private func control(
        _ title: String, _ icon: String, _ tint: Color, prominent: Bool = false, action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 22)
        }
        .tint(tint)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// 작은 버튼: 아이콘 위, 글자 아래
    private func smallButton(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(on ? Color.accentColor : Color.gray)
        .accessibilityValue(on ? "켬" : "끔")
    }
}

// MARK: - 소스 줄과 소스 추가

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
        .listRowBackground(selected ? Color.accentColor.opacity(0.35) : Color.clear)
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

// MARK: - 화면 방향과 화면 시험 (CI)

/// CI는 시뮬레이터 기기를 Simulator 앱의 메뉴로 돌린다(simctl에는 돌리는 명령이 없다). 그게 안 되면 앱이 창의 방향을 바꿔 달라고
/// 한다: 화면 배치는 같지만 기기는 세로라 가로 창이 세로 화면 안에 줄어 보인다. 카메라 방향은 기기 센서를 따르므로 실기기에서 본다.
enum ScreenOrientation {
    /// 지금 창 크기 (ContentView가 바뀔 때마다 넣는다)
    @MainActor static var windowSize = CGSize.zero

    /// `-orientation landscape|portrait`: 기기가 그 방향이 아니면 창 방향을 바꿔 달라고 한다
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
        if scene.effectiveGeometry.interfaceOrientation.isLandscape == landscape {
            appLog("orientation: already \(landscape ? "landscape" : "portrait")")
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

/// CI (`-autotest-ui`, 다시 띄운 실행): 세로로 뜬 화면에서 설정 시트를 연 채로 가로로 돌리고(시트가 남아야 한다),
/// 가로에서 소스 추가·소스 속성 시트를 하나씩 열고 채팅 패널과 상태 표시줄을 숨겨 본 뒤 다시 세로로 돌린다.
/// "ui autotest: shot <이름>"을 남기면 CI가 스크린숏을 찍고 tmp/autotest-shot 파일을 만든다. 그때까지 기다린다.
/// "ui autotest: rotate …"를 남기면 CI가 시뮬레이터 기기를 돌린다.
@MainActor
enum UIAutotest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-autotest-ui") else { return }
        Task { await run() }
    }

    private static func run() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { await pause(0.25) }
            return condition()
        }

        let ack = FileManager.default.temporaryDirectory.appendingPathComponent("autotest-shot")
        // 돌리거나 시트를 연 애니메이션이 끝나게 기다렸다가 알린다.
        // 느린 러너에서 simctl 스크린숏 한 장이 20초를 넘은 일이 있어(#83, #86) 넉넉히 기다린다
        func shot(_ name: String) async {
            await pause(1.5)
            try? FileManager.default.removeItem(at: ack)
            appLog("ui autotest: shot \(name)")
            let acked = await wait(45) { FileManager.default.fileExists(atPath: ack.path) }
            if !acked { appLog("ui autotest: no screenshot ack for \(name)") }
        }
        func sheet(_ sheet: String, shot name: String) async {
            NotificationCenter.default.post(name: .autotestSheet, object: sheet)
            await shot(name)
            NotificationCenter.default.post(name: .autotestSheet, object: nil)
            await pause(1)
        }
        func rotate(landscape: Bool) async {
            func rotated() -> Bool {
                let size = ScreenOrientation.windowSize
                return (size.width > size.height) == landscape
            }
            appLog("ui autotest: rotate \(landscape ? "landscape" : "portrait")")
            if await wait(10, until: rotated) { return }
            appLog("ui autotest: the device did not rotate")
            ScreenOrientation.request(landscape: landscape)
            _ = await wait(5, until: rotated)
        }

        appLog("ui autotest: start")
        UserDefaults.standard.set(true, forKey: AppSettings.chatPanelShown)
        await shot("1-portrait")

        // 시트를 연 채로 돌린다. 돌릴 때 화면이 새로 만들어지면 시트가 닫힌다
        // 메뉴 막대의 "설정…"(⌘,)과 같은 길로 연다
        NotificationCenter.default.post(name: .studioCommand, object: StudioCommand.settings.rawValue)
        await shot("2-settings")
        await rotate(landscape: true)
        await shot("3-settings-landscape")
        NotificationCenter.default.post(name: .autotestSheet, object: nil)
        await pause(1)
        await shot("4-landscape")

        await sheet("add source", shot: "5-add-source")
        // 맨 위 채팅 소스(장면 시험이 마지막에 넣은 YouTube 채팅, 속성에 상태 줄이 있다)가 있으면 그것을, 없으면 맨 위 소스
        let items = SceneModel.shared.items
        if let item = items.first(where: { $0.type == "ios_chat_source" }) ?? items.first {
            await sheet("properties:\(item.name)", shot: "6-properties")
        }
        // 채팅 패널을 숨기면 그 자리를 프리뷰와 독이 쓴다. 상태 표시줄도 숨기면 화면이 그만큼 위로 커진다
        UserDefaults.standard.set(false, forKey: AppSettings.chatPanelShown)
        UserDefaults.standard.set(false, forKey: AppSettings.statusBarShown)
        await shot("7-no-chat")

        UserDefaults.standard.set(true, forKey: AppSettings.chatPanelShown)
        UserDefaults.standard.set(true, forKey: AppSettings.statusBarShown)
        await rotate(landscape: false)
        await shot("8-portrait")
        appLog("ui autotest: done")

        // Liquid Glass 화면 (개발자 옵션, P10): 바꾸면 프리뷰를 다시 만들므로 위 시험(디스플레이가 그대로인지)이 끝난 뒤에.
        // 세로·가로로 찍고 원래 화면으로 되돌린다
        guard #available(iOS 26, *) else {
            appLog("ui autotest: glass skipped (iOS 26 or later)")
            return
        }
        UserDefaults.standard.set(true, forKey: AppSettings.developerMode)
        UserDefaults.standard.set(true, forKey: AppSettings.glassUI)
        await shot("9-glass-portrait")
        await rotate(landscape: true)
        await shot("10-glass-landscape")
        UserDefaults.standard.set(false, forKey: AppSettings.glassUI)
        UserDefaults.standard.set(false, forKey: AppSettings.developerMode)
        appLog("ui autotest: glass finished")
    }
}
