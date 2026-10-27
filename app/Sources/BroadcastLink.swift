import SwiftUI
import UIKit

/// 방송 링크 공유 (P13): 송출이 시작되면 시청 링크를 공유 창(카카오톡·X·복사 등)으로 띄운다.
/// 상태 줄·메뉴의 공유 단추로도 연다
enum BroadcastLink {
    /// 지금 송출이 어느 모드로 시작했는지
    enum Target {
        /// YouTube 계정 송출. 새 방송을 만들었으면 그 방송(영상) id
        case youtube(broadcastID: String?)
        case chzzk
        /// 서버·스트림 키 직접 입력 (RTMP·SRT)
        case manual

        var name: String {
            switch self {
            case .youtube: "youtube"
            case .chzzk: "chzzk"
            case .manual: "manual"
            }
        }
    }

    static let defaultTemplate = "방송을 시작했어요! {제목} {링크}"

    @MainActor private static let overlay = OverlayWindow()

    /// 시청 링크. 정할 수 없으면 nil (치지직 채널·직접 입력 링크를 설정하지 않음 등)
    static func url(for target: Target) -> URL? {
        let defaults = AppSettings.defaults
        switch target {
        case .youtube(let broadcastID):
            if let broadcastID, !broadcastID.isEmpty { return URL(string: "https://youtu.be/\(broadcastID)") }
            // 스트림 키만 쓰는 방식: 그 채널의 지금 라이브
            guard let channel = defaults.string(forKey: AppSettings.youtubeChannelID), !channel.isEmpty else { return nil }
            return URL(string: "https://www.youtube.com/channel/\(channel)/live")
        case .chzzk:
            return chzzkURL(defaults.string(forKey: AppSettings.chzzkChannel) ?? "")
        case .manual:
            let text = (defaults.string(forKey: AppSettings.broadcastLink) ?? "").trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased())
            else { return nil }
            return url
        }
    }

    /// 채널 ID(32자리 16진수)나 그것이 든 주소 → 라이브 주소. 다른 주소면 그대로
    static func chzzkURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "[0-9a-fA-F]{32}", options: .regularExpression) {
            return URL(string: "https://chzzk.naver.com/live/\(text[range].lowercased())")
        }
        guard let url = URL(string: text), url.scheme?.lowercased().hasPrefix("http") == true else { return nil }
        return url
    }

    /// 공유할 글: 문구 틀의 {제목}·{링크}를 채운다. {링크}가 없으면 끝에 붙인다
    static func message(for target: Target, url: URL) -> String {
        let defaults = AppSettings.defaults
        var template = defaults.string(forKey: AppSettings.shareTemplate) ?? defaultTemplate
        if template.trimmingCharacters(in: .whitespaces).isEmpty { template = defaultTemplate }
        var title = ""
        if case .youtube = target { title = defaults.string(forKey: AppSettings.youtubeTitle) ?? "" }
        var text = template.replacingOccurrences(of: "{제목}", with: title)
        if text.contains("{링크}") {
            text = text.replacingOccurrences(of: "{링크}", with: url.absoluteString)
        } else {
            text += " " + url.absoluteString
        }
        // 제목이 비어 생긴 겹친 빈칸
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 송출이 새로 시작됨 (재연결 아님). 설정이 켜져 있으면 공유 창을 띄운다. 어느 스레드에서나
    static func streamStarted(_ target: Target?) {
        guard let target else {
            appLog("share: streaming started without a mode (test stream), no link")
            return
        }
        onMain {
            current = target
            guard AppSettings.defaults.bool(forKey: AppSettings.shareOnStart) else { return }
            share(target, automatic: true)
        }
    }

    /// 지금 송출의 모드 (공유 단추가 쓴다)
    @MainActor private(set) static var current: Target?

    /// 공유 단추 (상태 줄·메뉴)
    @MainActor static func shareCurrent() {
        share(current ?? .manual, automatic: false)
    }

    @MainActor private static func share(_ target: Target, automatic: Bool) {
        // YouTube 스트림 키 방식인데 채널 ID를 아직 모르면(예전에 로그인) 받아 온 뒤에
        if case .youtube(nil) = target, url(for: target) == nil, YouTubeAccount.shared.loggedIn {
            Task {
                try? await YouTubeAccount.shared.refreshChannel()
                await MainActor.run { present(target, automatic: automatic) }
            }
            return
        }
        present(target, automatic: automatic)
    }

    @MainActor private static func present(_ target: Target, automatic: Bool) {
        guard let url = url(for: target) else {
            appLog("share: no link for \(target.name)")
            if !automatic {
                OutputAlert.show(
                    title: "방송 링크가 없습니다", message: "설정 › 송출 › 방송 링크에서 채널이나 링크를 넣으세요.",
                    log: "share: no link")
            }
            return
        }
        let text = message(for: target, url: url)
        appLog("share: link \(url.absoluteString) (\(target.name))")
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            appLog("share: \(completed ? "completed \(activity?.rawValue ?? "")" : "cancelled")")
            MainActor.assumeIsolated { overlay.close() }
        }
        if overlay.present(controller) {
            appLog("share: sheet shown (\(automatic ? "stream started" : "button"))")
            if ProcessInfo.processInfo.arguments.contains("-autotest-share") {
                // CI: 몇 초 보이게 두었다가(스크린숏) 닫는다
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    MainActor.assumeIsolated {
                        overlay.close()
                        appLog("share autotest: ok (\(url.absoluteString))")
                    }
                }
            }
        } else {
            appLog("share: sheet not shown (app is not active)")
        }
    }
}

/// 설정 › 송출의 "방송 링크" 섹션
struct BroadcastLinkSection: View {
    let mode: String
    @AppStorage(AppSettings.shareOnStart) private var shareOnStart = true
    @AppStorage(AppSettings.shareTemplate) private var template = BroadcastLink.defaultTemplate
    @AppStorage(AppSettings.chzzkChannel) private var chzzkChannel = ""
    @AppStorage(AppSettings.broadcastLink) private var manualLink = ""
    @AppStorage(AppSettings.youtubeChannelID) private var youtubeChannelID = ""

    private var target: BroadcastLink.Target {
        switch mode {
        case "youtube": .youtube(broadcastID: nil)
        case "chzzk": .chzzk
        default: .manual
        }
    }

    var body: some View {
        Section {
            switch mode {
            case "youtube":
                LabeledContent("링크", value: "새 방송이면 그 방송의 youtu.be 링크")
                if !youtubeChannelID.isEmpty {
                    LabeledContent("스트림 키만 쓸 때", value: "채널의 라이브 페이지")
                }
            case "chzzk":
                TextField("치지직 채널 ID 또는 채널 주소", text: $chzzkChannel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            default:
                TextField("방송 링크 (https://…)", text: $manualLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            if mode != "youtube" {
                if let url = BroadcastLink.url(for: target) {
                    LabeledContent("공유할 링크", value: url.absoluteString)
                } else if !(mode == "chzzk" ? chzzkChannel : manualLink).isEmpty {
                    Text("링크로 읽을 수 없습니다.").font(.footnote).foregroundStyle(.red)
                }
            }
            Toggle("송출을 시작하면 공유 창 띄우기", isOn: $shareOnStart)
            TextField("문구", text: $template, axis: .vertical)
                .lineLimit(1...3)
        } header: {
            Text("방송 링크")
        } footer: {
            Text("문구의 {링크}는 시청 링크, {제목}은 YouTube 방송 제목으로 바뀝니다. 송출 중에는 상태 줄의 공유 단추로 다시 열 수 있습니다.")
        }
    }
}
