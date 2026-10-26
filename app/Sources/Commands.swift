import SwiftUI

/// 메뉴 막대와 키보드 단축키 (P10). iPadOS 26부터 화면 위쪽 메뉴 막대에 보이고,
/// 하드웨어 키보드에서 ⌘를 누르고 있으면 단축키 목록으로도 보인다.
/// 시트를 여는 일은 화면 쪽(StudioSheetsModifier)이 .studioCommand 알림으로 받는다
enum StudioCommand: String {
    case settings, addSource, properties, toggleStream, transform
}

extension Notification.Name {
    static let studioCommand = Notification.Name("studioCommand")
}

struct StudioCommands: Commands {
    @ObservedObject var outputs: Outputs
    @ObservedObject var model: SceneModel
    @AppStorage(AppSettings.previewEnabled) private var previewEnabled = true
    @AppStorage("showDiagnostics") private var showDiagnostics = true
    @AppStorage(AppSettings.chatPanelShown) private var chatShown = true
    @AppStorage(AppSettings.statusBarShown) private var statusBarShown = true
    @AppStorage(AppSettings.developerMode) private var developerMode = false
    @AppStorage(AppSettings.glassUI) private var glassUI = false

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("설정…") { post(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        // 창이 하나뿐인 앱이라 새 창은 없다
        CommandGroup(replacing: .newItem) {}

        CommandMenu("방송") {
            Button(outputs.stats.streaming ? "송출 중지" : "송출 시작") { post(.toggleStream) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(outputs.streamPreparing)
            Button(outputs.stats.recording ? "녹화 중지" : "녹화 시작") { outputs.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button(outputs.stats.replay_active ? "리플레이 버퍼 끄기" : "리플레이 버퍼 켜기") { outputs.toggleReplay() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("리플레이 저장") { outputs.saveReplay() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!outputs.stats.replay_active)
        }

        CommandMenu("장면") {
            // 앞의 장면 아홉 개는 ⌘1~⌘9. 지금 장면에 체크
            ForEach(Array(model.scenes.prefix(9).enumerated()), id: \.offset) { index, scene in
                Toggle(
                    scene,
                    isOn: Binding(get: { scene == model.currentScene }, set: { if $0 { model.switchTo(scene) } })
                )
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("이전 장면") { step(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("다음 장면") { step(1) }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("장면 추가") { model.addScene() }
        }

        CommandMenu("소스") {
            let item = model.selectedItem
            Button("소스 추가…") { post(.addSource) }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("속성…") { post(.properties) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(item == nil)
            Button(item?.visible == false ? "보이기" : "숨기기") {
                if let item { model.setVisible(item, !item.visible) }
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            .disabled(item == nil)
            Button("화면에 맞추기") {
                if let item { model.fit(item) }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(item == nil)
            // 미리보기 편집 (P11)
            Divider()
            Button("시계 방향으로 90° 돌리기") {
                if let item { model.rotate(item, by: 90) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(item == nil)
            Button("반시계 방향으로 90° 돌리기") {
                if let item { model.rotate(item, by: -90) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(item == nil)
            Button("좌우 뒤집기") {
                if let item { model.flip(item, horizontal: true) }
            }
            .disabled(item == nil)
            Button("상하 뒤집기") {
                if let item { model.flip(item, horizontal: false) }
            }
            .disabled(item == nil)
            Toggle("자르기", isOn: Binding(get: { model.cropMode }, set: { model.cropMode = $0 }))
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(item == nil)
            Button("변형 편집…") { post(.transform) }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(item == nil)
            Button("원래대로 (크기·회전·자르기)") {
                if let item { model.resetTransform(item) }
            }
            .disabled(item == nil)
        }

        // 보기 메뉴
        CommandGroup(after: .toolbar) {
            Toggle("미리보기", isOn: $previewEnabled)
            Toggle("계측", isOn: $showDiagnostics)
            Toggle("채팅 패널", isOn: $chatShown)
            Toggle("상태 표시줄", isOn: $statusBarShown)
            if developerMode {
                if #available(iOS 26, *) {
                    Divider()
                    Toggle("Liquid Glass 화면 (시험)", isOn: $glassUI)
                }
            }
        }
    }

    private func post(_ command: StudioCommand) {
        appLog("command: \(command.rawValue)")
        NotificationCenter.default.post(name: .studioCommand, object: command.rawValue)
    }

    private func step(_ offset: Int) {
        guard let index = model.scenes.firstIndex(of: model.currentScene), !model.scenes.isEmpty else { return }
        let count = model.scenes.count
        model.switchTo(model.scenes[(index + offset + count) % count])
    }
}
