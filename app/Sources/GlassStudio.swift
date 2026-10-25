import SwiftUI

/// 독과 상태 줄의 겉모양. Liquid Glass 화면은 회색 바탕을 빼고 패널 바깥에 유리를 씌운다
enum DockChrome {
    case classic, glass
}

extension EnvironmentValues {
    @Entry var dockChrome = DockChrome.classic
}

extension Outputs {
    var streamButtonTitle: String {
        if streamPreparing { return "방송 준비 중…" }
        if streamStopping { return "멈추는 중 (누르면 강제)" }
        return stats.streaming ? "송출 중지" : "송출 시작"
    }

    var recordButtonTitle: String {
        if recordStopping { return "멈추는 중 (누르면 강제)" }
        return stats.recording ? "녹화 중지" : "녹화 시작"
    }
}

/// Liquid Glass 화면 (P10, 개발자 옵션, iOS 26+): 프리뷰를 화면 가득 두고
/// 위에는 상태 캡슐, 아래에는 조작 막대, 장면·소스와 오디오·채팅은 떠 있는 유리 패널로 연다.
/// 가로면 장면·소스는 왼쪽, 오디오·채팅은 오른쪽 기둥. 세로면 마지막으로 연 패널 하나만 아래에서 올라온다.
/// 프리뷰는 패널과 따로 두어 돌려도 다시 만들지 않는다 (패널만 자리를 옮긴다)
@available(iOS 26, *)
struct GlassStudio: View {
    @ObservedObject var core: Core
    @ObservedObject var outputs: Outputs
    @ObservedObject var model: SceneModel
    @ObservedObject var diagnostics: Diagnostics
    @ObservedObject var sheets: StudioSheets
    let size: CGSize
    @Binding var showDiagnostics: Bool
    @Binding var chatShown: Bool
    @AppStorage(AppSettings.previewEnabled) private var previewEnabled = true
    @AppStorage("glassScenesShown") private var scenesShown = true
    @AppStorage("glassAudioShown") private var audioShown = false
    @State private var lastOpened = Panel.scenes

    enum Panel {
        case scenes, audio, chat
    }

    private var wide: Bool { StudioLayout.isWide(size) }

    var body: some View {
        ZStack {
            PreviewArea(core: core, model: model)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    StatusBar(outputs: outputs, diagnostics: diagnostics)
                        .fixedSize()
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .frame(maxWidth: .infinity)
                    if showDiagnostics {
                        DiagnosticsOverlay(diagnostics: diagnostics, outputs: outputs)
                            .allowsHitTesting(false)
                    }
                }
                panels
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controlBar
            }
            .padding(12)
        }
        .environment(\.dockChrome, .glass)
    }

    // MARK: 패널

    private func shown(_ panel: Panel) -> Bool {
        let open =
            switch panel {
            case .scenes: scenesShown
            case .audio: audioShown
            case .chat: chatShown
            }
        return open && (wide || panel == lastOpened)
    }

    private func toggle(_ panel: Panel) {
        let open = !shown(panel)
        withAnimation(.bouncy) {
            // 세로에서는 한 번에 하나만
            if !wide && open {
                scenesShown = false
                audioShown = false
                chatShown = false
            }
            switch panel {
            case .scenes: scenesShown = open
            case .audio: audioShown = open
            case .chat: chatShown = open
            }
            if open { lastOpened = panel }
        }
    }

    @ViewBuilder
    private var panels: some View {
        if wide {
            HStack(alignment: .top, spacing: 12) {
                if shown(.scenes) {
                    scenesPanel
                        .frame(width: 300)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if shown(.audio) || shown(.chat) {
                    VStack(spacing: 12) {
                        if shown(.audio) {
                            audioPanel.frame(height: shown(.chat) ? 260 : nil)
                        }
                        if shown(.chat) { chatPanel }
                    }
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    if shown(.scenes) {
                        scenesPanel
                    } else if shown(.audio) {
                        audioPanel
                    } else if shown(.chat) {
                        chatPanel
                    }
                }
                .frame(height: size.height * 0.42)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var scenesPanel: some View {
        VStack(spacing: 0) {
            ScenesDock(model: model, sheets: sheets)
                .frame(maxHeight: 220)
            Divider()
            SourcesDock(model: model, sheets: sheets)
        }
        .glassPanel()
    }

    private var audioPanel: some View {
        AudioDock(core: core, sheets: sheets)
            .glassPanel()
    }

    private var chatPanel: some View {
        Dock("채팅") {
            ChatPanelView(feed: ChatFeed.shared) { withAnimation(.bouncy) { chatShown = false } }
        }
        .glassPanel()
    }

    // MARK: 조작 막대

    private var controlBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                outputButton(
                    outputs.streamButtonTitle,
                    outputs.stats.streaming ? "stop.circle.fill" : "dot.radiowaves.left.and.right", .blue,
                    active: outputs.stats.streaming
                ) {
                    // 송출 서버를 정하지 않았거나 로그인하지 않았으면 설정의 송출 페이지를 연다
                    if !outputs.toggleStreaming() { sheets.openSettings(.stream) }
                }
                .disabled(outputs.streamPreparing)

                outputButton(
                    outputs.recordButtonTitle, outputs.stats.recording ? "stop.circle.fill" : "record.circle", .red,
                    active: outputs.stats.recording
                ) {
                    outputs.toggleRecording()
                }

                if outputs.stats.replay_active {
                    outputButton("리플레이 저장", "square.and.arrow.down", .green, active: true) { outputs.saveReplay() }
                    iconButton("리플레이 끄기", "stop.fill", on: false) { outputs.toggleReplay() }
                } else {
                    outputButton("리플레이 시작", "gobackward", .green, active: false) { outputs.toggleReplay() }
                }

                Spacer().frame(width: 6)

                iconButton("장면·소스", "square.stack.3d.up", on: shown(.scenes)) { toggle(.scenes) }
                iconButton("오디오", "speaker.wave.2", on: shown(.audio)) { toggle(.audio) }
                iconButton("채팅", "bubble.left.and.text.bubble.right", on: shown(.chat)) { toggle(.chat) }
                iconButton("계측", "gauge.with.dots.needle.67percent", on: showDiagnostics) { showDiagnostics.toggle() }
                iconButton("미리보기", previewEnabled ? "eye" : "eye.slash", on: previewEnabled) { previewEnabled.toggle() }
                iconButton("설정", "gearshape", on: false) { sheets.openSettings() }
            }
        }
    }

    /// 송출·녹화·리플레이. 켜져 있으면 색이 찬 유리. 폭이 좁으면(세로) 아이콘만
    @ViewBuilder
    private func outputButton(
        _ title: String, _ icon: String, _ color: Color, active: Bool, action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(size.width > 1000 ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .frame(minHeight: 30)
        }
        .accessibilityLabel(title)
        .controlSize(.large)
        if active {
            button.buttonStyle(.glassProminent).tint(color)
        } else {
            button.buttonStyle(.glass).foregroundStyle(color)
        }
    }

    /// 패널 열기·화면 켜고 끄기. 켜져 있으면 회색이 찬 유리
    @ViewBuilder
    private func iconButton(_ label: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .frame(width: 26, height: 30)
        }
        .accessibilityLabel(label)
        .controlSize(.large)
        if on {
            button.buttonStyle(.glassProminent).tint(Color(white: 0.45))
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// 라벨 모양을 조건에 따라 고르기 위한 지움 타입
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<Style: LabelStyle>(_ style: Style) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

@available(iOS 26, *)
extension View {
    /// 떠 있는 유리 패널 (둥근 사각형)
    fileprivate func glassPanel() -> some View {
        clipShape(.rect(cornerRadius: 22))
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
