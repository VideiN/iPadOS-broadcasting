import Security
import SwiftUI
import UniformTypeIdentifiers

/// 앱 설정 (UserDefaults 키와 기본값). 스트림 키만 Keychain에 둔다.
enum AppSettings {
    static let streamServer = "streamServer"
    static let streamCodec = "streamCodec"  // "h264" | "hevc"
    static let streamBitrate = "streamBitrate"  // kbps
    static let streamAudioBitrate = "streamAudioBitrate"
    static let recordCodec = "recordCodec"
    static let recordBitrate = "recordBitrate"
    static let recordAudioBitrate = "recordAudioBitrate"
    static let recordFolderBookmark = "recordFolderBookmark"
    static let canvasWidth = "canvasWidth"
    static let canvasHeight = "canvasHeight"
    static let canvasFPS = "canvasFPS"  // 예전 정수 fps (분수 키가 없을 때 읽는다)
    static let canvasFPSNum = "canvasFPSNum"  // 캔버스 fps 분자·분모 (29.97 = 30000/1001)
    static let canvasFPSDen = "canvasFPSDen"
    static let previewEnabled = "previewEnabled"  // 끄면 프리뷰 디스플레이를 없앤다 (출력용 캔버스는 계속 그린다)
    static let replaySeconds = "replaySeconds"  // 리플레이 버퍼 길이 (녹화 코덱·비트레이트를 같이 쓴다)
    static let streamMode = "streamMode"  // "manual"(서버·스트림 키 직접 입력) | "youtube"(계정, P8)
    static let youtubeClientID = "youtubeClientID"  // 사용자가 만든 Google OAuth 클라이언트 (iOS 유형)
    static let youtubeTokenClientID = "youtubeTokenClientID"  // 갱신 토큰을 받은 클라이언트 (빌드에 든 것 또는 위의 것)
    static let youtubeChannelTitle = "youtubeChannelTitle"  // 로그인한 채널 이름 (화면 표시용)
    static let youtubeBroadcastMode = "youtubeBroadcastMode"  // "new"(새 방송 만들기) | "key"(스트림 키만)
    static let youtubeTitle = "youtubeTitle"
    static let youtubeDescription = "youtubeDescription"
    static let youtubePrivacy = "youtubePrivacy"  // "public" | "unlisted" | "private"
    static let youtubeLatency = "youtubeLatency"  // "normal" | "low" | "ultraLow"
    static let youtubeStreamID = "youtubeStreamID"  // 이 앱이 만든 재사용 스트림
    static let youtubeOpenBroadcast = "youtubeOpenBroadcast"  // 이 앱이 만들어 아직 끝내지 않은 방송
    static let chatPanelShown = "chatPanelShown"  // 오른쪽 채팅 패널 (숨겨도 패널 페이지는 창 뒤에서 계속 돈다)
    static let statusBarShown = "statusBarShown"  // iPad 상태 표시줄 (시계·배터리). 보이면 그 자리는 비우고 아래부터 그린다
    static let faceLinkEnabled = "faceLinkEnabled"  // 아이폰 얼굴 추적 받기 (P9, UDP)
    static let faceLinkPort = "faceLinkPort"
    static let faceLinkToken = "faceLinkToken"  // 페어링 코드 (QR에 들어감)
    static let faceLinkAcceptVMC = "faceLinkAcceptVMC"  // 페어링 코드 없이 VMC로 보내는 다른 앱도 받기
    static let faceLinkAllowed = "faceLinkAllowed"  // 코드 없이 받기로 허락한 아이폰 (기기 이름|주소)
    static let settingsPage = "settingsPage"  // 설정에서 마지막으로 본 페이지
    static let developerMode = "developerMode"  // 개발자 옵션 (정보의 빌드 줄을 7번 누르면 켜진다)
    static let glassUI = "glassUI"  // Liquid Glass 새 화면 (개발자 옵션, iOS 26+)

    static func register() {
        UserDefaults.standard.register(defaults: [
            streamCodec: "h264",
            streamBitrate: 6000,
            streamAudioBitrate: 160,
            recordCodec: "hevc",
            recordBitrate: 20000,
            recordAudioBitrate: 192,
            canvasWidth: 1920,
            canvasHeight: 1080,
            canvasFPS: 60,
            replaySeconds: 30,
            streamMode: "manual",
            youtubeBroadcastMode: "new",
            youtubeTitle: "라이브 방송",
            youtubePrivacy: "unlisted",
            youtubeLatency: "normal",
            chatPanelShown: true,
            statusBarShown: true,
            faceLinkEnabled: false,
            faceLinkPort: 39539,
            faceLinkAcceptVMC: false,
        ])
    }

    static var defaults: UserDefaults { .standard }
}

/// 비밀값 하나를 Keychain에 둔다. LiveContainer 게스트에서 Keychain을 못 쓰면 UserDefaults에 둔다.
struct SecretItem {
    let service: String
    let fallbackKey: String

    func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        return UserDefaults.standard.string(forKey: fallbackKey) ?? ""
    }

    func save(_ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            return
        }

        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)

        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            appLog("keychain unavailable (\(status)), \(fallbackKey) kept in app settings")
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
    }
}

/// 스트림 키는 Keychain에 둔다
enum StreamKeyStore {
    private static let item = SecretItem(service: "io.github.videin.broadcast.stream-key", fallbackKey: "streamKey")

    static func load() -> String { item.load() }
    static func save(_ key: String) { item.save(key) }
}

/// 녹화 폴더: 기본은 Documents/Recordings, 고르면 그 폴더(외장 SSD 등)를 보안 범위 북마크로 기억한다
enum RecordingFolder {
    static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remember(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData()
            UserDefaults.standard.set(bookmark, forKey: AppSettings.recordFolderBookmark)
            appLog("recording folder set to \(url.path)")
            return true
        } catch {
            appLog("bookmark failed for \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: AppSettings.recordFolderBookmark)
    }

    /// 고른 폴더 (접근을 시작한 상태). 없거나 접근할 수 없으면 nil
    static func resolveChosen() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: AppSettings.recordFolderBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            appLog("recording folder bookmark could not be resolved")
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            appLog("no access to the recording folder \(url.path)")
            return nil
        }
        if stale { _ = remember(url) }
        return url
    }

    static var displayName: String {
        guard let bookmark = UserDefaults.standard.data(forKey: AppSettings.recordFolderBookmark) else {
            return "앱 문서 폴더 / Recordings"
        }
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        return url?.lastPathComponent ?? "(찾을 수 없음)"
    }
}

// MARK: - 설정 화면

/// 설정 화면의 페이지 (왼쪽 사이드바 목록)
enum SettingsPage: String, CaseIterable, Identifiable {
    case stream, record, replay, canvas, display, faceTracking, about, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stream: "송출"
        case .record: "녹화"
        case .replay: "리플레이 버퍼"
        case .canvas: "캔버스"
        case .display: "화면"
        case .faceTracking: "얼굴 추적"
        case .about: "정보"
        case .developer: "개발자"
        }
    }

    var icon: String {
        switch self {
        case .stream: "dot.radiowaves.left.and.right"
        case .record: "record.circle"
        case .replay: "gobackward"
        case .canvas: "rectangle.dashed"
        case .display: "ipad.landscape"
        case .faceTracking: "face.smiling"
        case .about: "info.circle"
        case .developer: "hammer"
        }
    }
}

/// 설정 시트: 왼쪽은 페이지 목록, 오른쪽은 고른 페이지. 시트 폭이 좁으면 목록에서 눌러 들어가는 방식으로 바뀐다
struct SettingsView: View {
    @ObservedObject var core: Core
    @ObservedObject var outputs: Outputs
    /// 열 때 보일 페이지 (송출을 시작하지 못해 열면 송출). nil이면 마지막으로 본 페이지
    var initialPage: SettingsPage?

    @AppStorage(AppSettings.settingsPage) private var savedPage = SettingsPage.stream.rawValue
    @AppStorage(AppSettings.developerMode) private var developerMode = false
    @State private var page: SettingsPage?
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.dismiss) private var dismiss

    private var pages: [SettingsPage] {
        SettingsPage.allCases.filter { $0 != .developer || developerMode }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(pages, selection: $page) { page in
                NavigationLink(value: page) {
                    Label(page.title, systemImage: page.icon)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        } detail: {
            // 페이지를 바꾸면 그 안에서 들어간 화면(진단과 로그 등)은 닫는다
            NavigationStack {
                detail(page ?? .stream)
                    .navigationTitle((page ?? .stream).title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .id(page)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            let saved = SettingsPage(rawValue: savedPage) ?? .stream
            page = initialPage ?? (pages.contains(saved) ? saved : .stream)
            appLog("settings: page \(page?.rawValue ?? "-")")
        }
        .onChange(of: page) { _, page in
            if let page { savedPage = page.rawValue }
        }
        .onChange(of: developerMode) { _, on in
            if !on && page == .developer { page = .about }
        }
    }

    @ViewBuilder
    private func detail(_ page: SettingsPage) -> some View {
        switch page {
        case .stream: StreamSettingsPage(outputs: outputs)
        case .record: RecordSettingsPage(outputs: outputs)
        case .replay: ReplaySettingsPage(outputs: outputs)
        case .canvas: CanvasSettingsPage(core: core, outputs: outputs)
        case .display: DisplaySettingsPage()
        case .faceTracking: FaceLinkSettingsView()
        case .about: AboutSettingsPage()
        case .developer: DeveloperSettingsPage()
        }
    }
}

private let audioBitrates = [96, 128, 160, 192, 256, 320]

private struct StreamSettingsPage: View {
    @ObservedObject var outputs: Outputs
    @ObservedObject private var youtube = YouTubeAccount.shared
    @AppStorage(AppSettings.streamServer) private var server = ""
    @AppStorage(AppSettings.streamMode) private var streamMode = "manual"
    @AppStorage(AppSettings.streamCodec) private var streamCodec = "h264"
    @AppStorage(AppSettings.streamBitrate) private var streamBitrate = 6000
    @AppStorage(AppSettings.streamAudioBitrate) private var streamAudioBitrate = 160
    @State private var streamKey = ""

    var body: some View {
        Form {
            Section {
                Picker("방식", selection: $streamMode) {
                    Text("서버·스트림 키 입력").tag("manual")
                    Text("YouTube 계정").tag("youtube")
                }
                if streamMode == "youtube" {
                    YouTubeAccountRows(account: youtube)
                } else {
                    TextField("rtmp://…, rtmps://… 또는 srt://…", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("스트림 키", text: $streamKey)
                        .onChange(of: streamKey) { _, key in StreamKeyStore.save(key) }
                }
            } header: {
                Text("보낼 곳")
            } footer: {
                if streamMode == "youtube" {
                    Text("YouTube 계정으로 로그인하면 송출할 때 스트림 키를 자동으로 받습니다. 로그인 정보는 Keychain에 저장합니다.")
                } else {
                    Text(
                        "예: rtmp://live.twitch.tv/app, rtmps://a.rtmps.youtube.com:443/live2, srt://서버:포트. SRT는 스트림 키를 streamid로 보내고, 암호는 URL 끝에 ?passphrase=… 로 넣습니다. 스트림 키는 Keychain에 저장합니다."
                    )
                }
            }
            .disabled(outputs.stats.streaming)

            if streamMode == "youtube" && youtube.loggedIn {
                YouTubeBroadcastSection()
                    .disabled(outputs.stats.streaming)
            }

            Section {
                Picker("코덱", selection: $streamCodec) {
                    Text("H.264").tag("h264")
                    Text("HEVC (Enhanced RTMP)").tag("hevc")
                }
                Stepper("비디오 \(streamBitrate) kbps (CBR)", value: $streamBitrate, in: 1000...50000, step: 500)
                Picker("오디오 (AAC)", selection: $streamAudioBitrate) {
                    ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            } header: {
                Text("인코딩")
            } footer: {
                Text(streamMode == "youtube" ? "HEVC는 YouTube가 받습니다 (Enhanced RTMP)." : "HEVC는 받는 플랫폼이 지원할 때만 쓰세요.")
            }
            .disabled(outputs.stats.streaming)
        }
        .onAppear { streamKey = StreamKeyStore.load() }
    }
}

private struct RecordSettingsPage: View {
    @ObservedObject var outputs: Outputs
    @AppStorage(AppSettings.recordCodec) private var recordCodec = "hevc"
    @AppStorage(AppSettings.recordBitrate) private var recordBitrate = 20000
    @AppStorage(AppSettings.recordAudioBitrate) private var recordAudioBitrate = 192
    @State private var pickingFolder = false
    @State private var folderName = RecordingFolder.displayName

    var body: some View {
        Form {
            Section {
                Picker("코덱", selection: $recordCodec) {
                    Text("HEVC").tag("hevc")
                    Text("H.264").tag("h264")
                }
                Stepper("비디오 \(recordBitrate / 1000) Mbps", value: $recordBitrate, in: 5000...150000, step: 5000)
                Picker("오디오 (AAC)", selection: $recordAudioBitrate) {
                    ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            } header: {
                Text("Hybrid MP4")
            } footer: {
                Text("녹화 중에 앱이 강제로 끝나도 파일을 살릴 수 있는 형식입니다.")
            }

            Section("저장 위치") {
                LabeledContent("폴더", value: folderName)
                Button("다른 폴더 선택… (외장 저장장치 등)") { pickingFolder = true }
                if UserDefaults.standard.data(forKey: AppSettings.recordFolderBookmark) != nil {
                    Button("앱 문서 폴더로 되돌리기") {
                        RecordingFolder.forget()
                        folderName = RecordingFolder.displayName
                    }
                }
            }
        }
        .disabled(outputs.stats.recording)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, RecordingFolder.remember(url) {
                folderName = RecordingFolder.displayName
            }
        }
    }
}

private struct ReplaySettingsPage: View {
    @ObservedObject var outputs: Outputs
    @AppStorage(AppSettings.replaySeconds) private var replaySeconds = 30

    var body: some View {
        Form {
            Section {
                Picker("길이", selection: $replaySeconds) {
                    ForEach([10, 15, 30, 60, 120, 300], id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds)초" : "\(seconds / 60)분").tag(seconds)
                    }
                }
            } footer: {
                Text("켜 두면 마지막 장면을 메모리에 두었다가 \"리플레이 저장\"을 누를 때 앱의 Recordings 폴더에 MP4로 저장합니다. 녹화 코덱·비트레이트를 같이 씁니다.")
            }
            .disabled(outputs.stats.replay_active)
        }
    }
}

/// 캔버스 fps: 흔한 값 목록과 직접 입력 (분수 30000/1001, 소수 29.97, 정수 24)
extension FrameRateChoice {
    static let canvasRange = 1.0...120.0

    static let canvasPresets: [FrameRateChoice] = [
        .init(numerator: 24000, denominator: 1001), .init(numerator: 24, denominator: 1),
        .init(numerator: 25, denominator: 1), .init(numerator: 30000, denominator: 1001),
        .init(numerator: 30, denominator: 1), .init(numerator: 48, denominator: 1),
        .init(numerator: 50, denominator: 1), .init(numerator: 60000, denominator: 1001),
        .init(numerator: 60, denominator: 1), .init(numerator: 120, denominator: 1),
    ]

    /// "30000/1001", "29.97", "24" → 약분한 분수. 23.976·29.97·59.94 같은 값은 정확한 /1001로 바꾼다
    init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var numerator: Int
        var denominator: Int
        if parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]) {
            (numerator, denominator) = (n, d)
        } else if parts.count == 1, let value = Double(parts[0]), value > 0, value < 100_000 {
            if let base = [24, 30, 48, 60, 120].first(where: { abs(value - Double($0 * 1000) / 1001) < 0.006 }) {
                (numerator, denominator) = (base * 1000, 1001)
            } else if value == value.rounded() {
                (numerator, denominator) = (Int(value), 1)
            } else {
                (numerator, denominator) = (Int((value * 1000).rounded()), 1000)
            }
        } else {
            return nil
        }
        guard (1...10_000_000).contains(numerator), (1...10_000_000).contains(denominator) else { return nil }
        var (a, b) = (numerator, denominator)
        while b != 0 { (a, b) = (b, a % b) }
        self.init(numerator: numerator / a, denominator: denominator / a)
    }

    /// 로그용: "30", "29.97 (30000/1001)"
    var logText: String {
        denominator == 1 ? "\(numerator)" : String(format: "%.2f (%ld/%ld)", fps, numerator, denominator)
    }
}

private struct CanvasSettingsPage: View {
    @ObservedObject var core: Core
    @ObservedObject var outputs: Outputs
    @State private var size = CanvasSize(width: 1920, height: 1080)
    /// 목록에서 고른 값 ("분자/분모") 또는 "custom"
    @State private var rateTag = "60/1"
    @State private var customText = ""
    @State private var canvasMessage = ""

    struct CanvasSize: Hashable {
        var width: UInt32
        var height: UInt32
    }

    private let resolutions: [(String, CanvasSize)] = [
        ("1280×720", .init(width: 1280, height: 720)), ("1920×1080", .init(width: 1920, height: 1080)),
        ("2560×1440", .init(width: 2560, height: 1440)), ("3840×2160", .init(width: 3840, height: 2160)),
    ]

    private static func tag(_ rate: FrameRateChoice) -> String { "\(rate.numerator)/\(rate.denominator)" }

    /// 고른 fps. 직접 입력이 틀렸거나 범위 밖이면 nil
    private var frameRate: FrameRateChoice? {
        let rate =
            rateTag == "custom"
            ? FrameRateChoice(text: customText) : FrameRateChoice.canvasPresets.first { Self.tag($0) == rateTag }
        return rate.flatMap { FrameRateChoice.canvasRange.contains($0.fps) ? $0 : nil }
    }

    var body: some View {
        Form {
            Section {
                Picker("해상도", selection: $size) {
                    ForEach(resolutions, id: \.0) { Text($0.0).tag($0.1) }
                }
                Picker("프레임", selection: $rateTag) {
                    ForEach(FrameRateChoice.canvasPresets, id: \.self) { Text($0.label).tag(Self.tag($0)) }
                    Text("직접 입력…").tag("custom")
                }
                if rateTag == "custom" {
                    TextField("예: 30000/1001, 29.97, 24", text: $customText)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    if let frameRate {
                        LabeledContent("적용할 값", value: "\(frameRate.label) (\(frameRate.numerator)/\(frameRate.denominator))")
                    } else if !customText.isEmpty {
                        Text("1~120 fps 사이의 숫자나 분수(분자/분모)를 넣으세요.").font(.footnote).foregroundStyle(.red)
                    }
                }
                Button("적용") {
                    guard let frameRate else { return }
                    canvasMessage = core.applyCanvas(width: size.width, height: size.height, frameRate: frameRate)
                        ? "바꿨습니다. 맞지 않는 소스는 ⋯ 메뉴의 '화면에 맞추기'를 쓰세요."
                        : "바꾸지 못했습니다. 녹화·송출을 멈춘 뒤 다시 해 보세요."
                }
                .disabled(
                    outputs.stats.recording || outputs.stats.streaming || frameRate == nil
                        || (size == CanvasSize(width: core.width, height: core.height) && frameRate == core.frameRate))
                if !canvasMessage.isEmpty {
                    Text(canvasMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                if let frameRate, frameRate.fps > 60.01 {
                    Text("녹화·송출 중에는 바꿀 수 없습니다. 송출 플랫폼 대부분은 60 fps까지 받습니다.")
                } else {
                    Text("녹화·송출 중에는 바꿀 수 없습니다. 29.97·59.94처럼 방송 장비와 맞출 값은 분수(30000/1001)로 정확히 들어갑니다.")
                }
            }
        }
        .onAppear {
            size = CanvasSize(width: core.width, height: core.height)
            if FrameRateChoice.canvasPresets.contains(core.frameRate) {
                rateTag = Self.tag(core.frameRate)
            } else {
                rateTag = "custom"
                customText = Self.tag(core.frameRate)
            }
        }
    }
}

private struct DisplaySettingsPage: View {
    @AppStorage(AppSettings.statusBarShown) private var statusBarShown = true

    var body: some View {
        Form {
            Section {
                Toggle("상태 표시줄 보이기", isOn: $statusBarShown)
            } footer: {
                Text("iPad 맨 위의 시계·배터리·Wi-Fi 줄입니다. 보이게 하면 그 자리는 비워 두고 앱 화면은 그 아래부터 그립니다.")
            }
        }
    }
}

private struct AboutSettingsPage: View {
    var body: some View {
        Form {
            Section {
                BuildInfoRows()
                LabeledContent("버전", value: appVersion)
            }
            Section {
                NavigationLink("진단과 로그") { DiagnosticsView() }
                NavigationLink("오픈소스 라이선스") { LicensesView() }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// 개발자 옵션 (정보의 빌드 줄을 7번 누르면 보인다)
private struct DeveloperSettingsPage: View {
    @AppStorage(AppSettings.developerMode) private var developerMode = false
    @AppStorage(AppSettings.glassUI) private var glassUI = false

    var body: some View {
        Form {
            Section {
                if #available(iOS 26, *) {
                    Toggle("Liquid Glass 화면 (시험)", isOn: $glassUI)
                } else {
                    LabeledContent("Liquid Glass 화면", value: "iPadOS 26 이상")
                }
            } footer: {
                Text("프리뷰를 화면 가득 두고 장면·소스·오디오·채팅을 떠 있는 유리 패널로 여는 새 화면입니다. 아직 시험 중입니다.")
            }
            Section {
                Button("개발자 옵션 숨기기", role: .destructive) {
                    glassUI = false
                    developerMode = false
                    appLog("developer options hidden")
                }
            }
        }
    }
}

// MARK: - 진단 화면

struct DiagnosticsView: View {
    @State private var lines: [String] = []

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private let logURL = Self.documents.appendingPathComponent("broadcast.log")
    private let previousLogURL = Self.documents.appendingPathComponent("broadcast.log.prev")

    var body: some View {
        List {
            Section {
                ShareLink(item: logURL) { Label("지금 로그 내보내기", systemImage: "square.and.arrow.up") }
                if FileManager.default.fileExists(atPath: previousLogURL.path) {
                    ShareLink(item: previousLogURL) {
                        Label("이전 실행 로그 내보내기", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("로그 파일")
            } footer: {
                Text("파일 앱에서도 이 앱의 Documents 폴더에서 볼 수 있습니다. 앱이 죽으면 이전 실행 로그 끝에 '*** crash' 기록이 남습니다.")
            }

            Section("최근 로그 (마지막 300줄)") {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(line))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("진단과 로그")
        .toolbar {
            Button("새로고침", systemImage: "arrow.clockwise", action: load)
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            lines = ["(로그를 읽을 수 없습니다)"]
            return
        }
        lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(300).map(String.init))
    }

    private func color(_ line: String) -> Color {
        if line.contains("error:") || line.contains("*** crash") { return .red }
        if line.contains("warning:") { return .orange }
        return .primary
    }
}

// MARK: - 라이선스 화면

struct LicensesView: View {
    private struct Entry: Identifiable {
        let file: String
        let title: String
        let license: String
        var id: String { file }
    }

    private let entries = [
        Entry(file: "app", title: "이 앱", license: "GPL-2.0-or-later"),
        Entry(file: "obs-studio", title: "OBS Studio (libobs, 플러그인)", license: "GPL-2.0-or-later"),
        Entry(file: "ffmpeg", title: "FFmpeg", license: "LGPL-2.1-or-later"),
        Entry(file: "librtmp", title: "librtmp (obs-outputs)", license: "LGPL-2.1"),
        Entry(file: "rnnoise", title: "RNNoise (obs-filters 노이즈 억제)", license: "BSD-3-Clause"),
        Entry(file: "mbedtls", title: "Mbed TLS", license: "Apache-2.0 또는 GPL-2.0-or-later"),
        Entry(file: "srt", title: "SRT (libsrt)", license: "MPL-2.0"),
        Entry(file: "jansson", title: "Jansson", license: "MIT"),
        Entry(file: "libcaption", title: "libcaption", license: "MIT"),
        Entry(file: "simde", title: "SIMDe", license: "MIT"),
        Entry(file: "uthash", title: "uthash", license: "BSD-1-Clause"),
        Entry(file: "vrmkit", title: "VRMKit (아바타 소스)", license: "MIT"),
    ]

    var body: some View {
        List {
            Section {
                Text(
                    "이 앱은 OBS Studio를 바탕으로 만들었으며 OBS Project와 관계가 없고 승인을 받지 않았습니다. 이 앱은 GPL 버전 2 이상으로 배포되며, 전체 소스 코드는 아래 저장소에 있습니다."
                )
                Link("github.com/VideiN/iPadOS-broadcasting", destination: URL(string: "https://github.com/VideiN/iPadOS-broadcasting")!)
            }

            Section("구성 요소") {
                ForEach(entries) { entry in
                    NavigationLink {
                        LicenseText(title: entry.title, file: entry.file)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.title)
                            Text(entry.license).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("오픈소스 라이선스")
    }
}

private struct LicenseText: View {
    let title: String
    let file: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "licenses"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "(라이선스 파일을 찾을 수 없습니다)" }
        return text
    }
}
