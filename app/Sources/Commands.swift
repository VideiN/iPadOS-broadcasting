import Combine
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

/// 메뉴가 보는 값만, 바뀔 때만 (P13). Outputs는 1초마다, SceneModel은 선택 상자·끌기 중에 자주 알리는데,
/// 메뉴가 그것들을 직접 보면 그때마다 메뉴 막대를 다시 만들어 열어 둔 메뉴가 닫히고 깜빡였다 (실기기 #131)
final class MenuState: ObservableObject {
    struct Item: Equatable {
        var visible: Bool
    }

    @Published private(set) var streaming = false
    @Published private(set) var recording = false
    @Published private(set) var replay = false
    @Published private(set) var preparing = false
    @Published private(set) var scenes: [String] = []
    @Published private(set) var currentScene = ""
    @Published private(set) var item: Item?
    @Published private(set) var cropMode = false

    private var subscriptions: Set<AnyCancellable> = []

    init(outputs: Outputs, model: SceneModel) {
        outputs.$stats.map(\.streaming).removeDuplicates().sink { [weak self] in self?.streaming = $0 }
            .store(in: &subscriptions)
        outputs.$stats.map(\.recording).removeDuplicates().sink { [weak self] in self?.recording = $0 }
            .store(in: &subscriptions)
        outputs.$stats.map(\.replay_active).removeDuplicates().sink { [weak self] in self?.replay = $0 }
            .store(in: &subscriptions)
        outputs.$streamPreparing.removeDuplicates().sink { [weak self] in self?.preparing = $0 }
            .store(in: &subscriptions)
        model.$scenes.removeDuplicates().sink { [weak self] in self?.scenes = $0 }.store(in: &subscriptions)
        model.$currentScene.removeDuplicates().sink { [weak self] in self?.currentScene = $0 }.store(in: &subscriptions)
        model.$items.combineLatest(model.$selection)
            .map { items, selection in items.first { $0.id == selection }.map { Item(visible: $0.visible) } }
            .removeDuplicates()
            .sink { [weak self] in self?.item = $0 }
            .store(in: &subscriptions)
        model.$cropMode.removeDuplicates().sink { [weak self] in self?.cropMode = $0 }.store(in: &subscriptions)
    }
}

struct StudioCommands: Commands {
    let outputs: Outputs
    let model: SceneModel
    @ObservedObject var menu: MenuState
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
            Button(menu.streaming ? "송출 중지" : "송출 시작") { post(.toggleStream) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(menu.preparing)
            Button(menu.recording ? "녹화 중지" : "녹화 시작") { outputs.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button(menu.replay ? "리플레이 버퍼 끄기" : "리플레이 버퍼 켜기") { outputs.toggleReplay() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("리플레이 저장") { outputs.saveReplay() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!menu.replay)
            Divider()
            Button("방송 링크 공유") { BroadcastLink.shareCurrent() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!menu.streaming)
        }

        CommandMenu("장면") {
            // 앞의 장면 아홉 개는 ⌘1~⌘9. 지금 장면에 체크
            ForEach(Array(menu.scenes.prefix(9).enumerated()), id: \.offset) { index, scene in
                Toggle(
                    scene,
                    isOn: Binding(get: { scene == menu.currentScene }, set: { if $0 { model.switchTo(scene) } })
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
            // 고른 항목 (메뉴는 있는지·보이는지만 본다, 누를 때 지금 항목을 다시 읽는다)
            let item = menu.item
            Button("소스 추가…") { post(.addSource) }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("속성…") { post(.properties) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(item == nil)
            Button(item?.visible == false ? "보이기" : "숨기기") {
                if let item = model.selectedItem { model.setVisible(item, !item.visible) }
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            .disabled(item == nil)
            Button("화면에 맞추기") {
                if let item = model.selectedItem { model.fit(item) }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(item == nil)
            // 미리보기 편집 (P11)
            Divider()
            Button("시계 방향으로 90° 돌리기") {
                if let item = model.selectedItem { model.rotate(item, by: 90) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(item == nil)
            Button("반시계 방향으로 90° 돌리기") {
                if let item = model.selectedItem { model.rotate(item, by: -90) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(item == nil)
            Button("좌우 뒤집기") {
                if let item = model.selectedItem { model.flip(item, horizontal: true) }
            }
            .disabled(item == nil)
            Button("상하 뒤집기") {
                if let item = model.selectedItem { model.flip(item, horizontal: false) }
            }
            .disabled(item == nil)
            Toggle("자르기", isOn: Binding(get: { menu.cropMode }, set: { model.cropMode = $0 }))
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(item == nil)
            Button("변형 편집…") { post(.transform) }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(item == nil)
            Button("원래대로 (크기·회전·자르기)") {
                if let item = model.selectedItem { model.resetTransform(item) }
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
