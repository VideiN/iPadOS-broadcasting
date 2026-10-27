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
    static let streamMode = "streamMode"  // "manual"(서버·스트림 키 직접 입력) | "youtube"(계정, P8) | "chzzk"(치지직 스트림 키, P10)
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
    static let replayMaxMB = "replayMaxMB"  // 리플레이 버퍼가 메모리에 둘 최대 크기 (P11)
    static let chzzkKeyint = "chzzkKeyint"  // 치지직 키프레임 간격 (권장 1초, 2초도 받는다)
    static let canvasColorSpace = "canvasColorSpace"  // enum video_colorspace (1 601, 2 709, 3 sRGB)
    static let canvasRange = "canvasRange"  // enum video_range_type (1 제한, 2 전체)
    static let canvasScale = "canvasScale"  // 출력 크기가 다를 때의 스케일 필터 (enum obs_scale_type)
    static let audioSampleRate = "audioSampleRate"  // 다음 실행부터
    static let audioChannels = "audioChannels"
    static let audioFixedBuffering = "audioFixedBuffering"  // 오디오 버퍼링 고정 128ms (P13, 다음 실행부터)
    // 송출 연결 (P11)
    static let streamDynBitrate = "streamDynBitrate"
    static let streamReconnect = "streamReconnect"
    static let streamRetries = "streamRetries"
    static let streamRetrySeconds = "streamRetrySeconds"
    static let streamDelay = "streamDelay"
    // 방송 링크 공유 (P13)
    static let shareOnStart = "shareOnStart"  // 송출을 시작하면 공유 창
    static let shareTemplate = "shareTemplate"  // 공유 문구 ({제목}, {링크})
    static let chzzkChannel = "chzzkChannel"  // 치지직 채널 ID 또는 주소
    static let broadcastLink = "broadcastLink"  // 직접 입력 송출의 시청 링크
    static let youtubeChannelID = "youtubeChannelID"  // 로그인한 채널 ID (스트림 키만 쓸 때 라이브 링크)
    // 백그라운드 송출 (P13)
    static let backgroundLive = "backgroundLive"  // 앱을 떠나도 송출·녹화를 계속
    static let backgroundScene = "backgroundScene"  // "" 자동 자리 비움 화면, "*" 지금 장면 그대로, 그 밖은 장면 이름
    static let backgroundMute = "backgroundMute"  // 자리 비움 동안 소리 끄기
    static let awayImage = "awayImage"  // 자동 자리 비움 화면의 이미지 (Documents/Media 안 경로, 없으면 글자만)

    /// 인코딩 설정 키 (P11): 송출은 "stream…", 녹화(리플레이 포함)는 "record…"
    enum EncoderKey: String, CaseIterable {
        case codec = "Codec", bitrate = "Bitrate", audioBitrate = "AudioBitrate"  // 예전부터 있던 키
        case rateControl = "RateControl", quality = "Quality", limitBitrate = "LimitBitrate"
        case maxBitrate = "MaxBitrate", maxBitrateWindow = "MaxBitrateWindow", keyint = "Keyint"
        case profile = "Profile", bframes = "BFrames", outputHeight = "OutputHeight", heAAC = "HEAAC"
    }

    static func key(_ target: EncoderSettings.Target, _ key: EncoderKey) -> String {
        target.rawValue + key.rawValue
    }

    static func register() {
        var encoderDefaults: [String: Any] = [:]
        for target in EncoderSettings.Target.allCases {
            let base = EncoderSettings.defaults(target)
            encoderDefaults[key(target, .rateControl)] = base.rateControl
            encoderDefaults[key(target, .quality)] = base.quality
            encoderDefaults[key(target, .limitBitrate)] = base.limitBitrate
            encoderDefaults[key(target, .maxBitrate)] = base.maxBitrateKbps
            encoderDefaults[key(target, .maxBitrateWindow)] = base.maxBitrateWindow
            encoderDefaults[key(target, .keyint)] = base.keyintSeconds
            encoderDefaults[key(target, .profile)] = base.profile
            encoderDefaults[key(target, .bframes)] = base.bframes
            encoderDefaults[key(target, .outputHeight)] = 0
            encoderDefaults[key(target, .heAAC)] = false
        }
        UserDefaults.standard.register(defaults: encoderDefaults)
        UserDefaults.standard.register(defaults: [
            replayMaxMB: 2048,
            chzzkKeyint: 1,
            canvasColorSpace: 2,
            canvasRange: 1,
            canvasScale: 2,
            audioSampleRate: 48000,
            audioChannels: 2,
            audioFixedBuffering: true,
            streamDynBitrate: false,
            streamReconnect: true,
            streamRetries: 20,
            streamRetrySeconds: 5,
            streamDelay: 0,
            shareOnStart: true,
            backgroundLive: true,
            backgroundMute: false,
        ])
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

/// 치지직 (P10, 1단계: 스트림 키로 송출). 서버와 권장값은 OBS rtmp-services의 CHZZK 항목
enum Chzzk {
    static let server = "rtmp://global-rtmp.lip2.navercorp.com:8080/relay"
    static let keyPage = URL(string: "https://studio.chzzk.naver.com/setting")!
    static let maxVideoKbps = 8000
    static let maxAudioKbps = 192
    static let maxFPS = 60.0
    static let maxHeight = 1080
    static let maxKeyint = 2
    /// 치지직 스트림 키는 직접 입력한 키와 따로 둔다 (방식을 바꿔도 섞이지 않게)
    static let keyStore = SecretItem(service: "io.github.videin.broadcast.stream-key.chzzk", fallbackKey: "chzzkStreamKey")
}

/// 비디오·오디오 인코딩 (P11). 송출과 녹화(리플레이 포함)가 각자의 키로 저장한다.
/// 치지직이면 그 권장값(H.264, CBR, B프레임 없음, 최대 비트레이트·1080p)으로 덮어쓴다 (키프레임은 1·2초 중 고른 값)
struct EncoderSettings: Equatable {
    enum Target: String, CaseIterable {
        case stream, record
    }

    var codec = "h264"  // "h264" | "hevc"
    var rateControl = "CBR"  // "CBR" | "ABR" | "CRF"
    var videoKbps = 6000
    var quality = 60  // CRF 0~100
    var limitBitrate = false  // ABR·CRF만
    var maxBitrateKbps = 0  // 0이면 비디오 비트레이트
    var maxBitrateWindow = 1.5  // 초
    var keyintSeconds = 2
    var profile = "high"  // H.264: "baseline" | "main" | "high"
    var bframes = true
    var outputHeight = 0  // 0이면 캔버스 크기. 폭은 캔버스 비율을 따른다
    var audioKbps = 160
    var heAAC = false

    static func defaults(_ target: Target) -> EncoderSettings {
        switch target {
        case .stream: EncoderSettings()
        case .record: EncoderSettings(codec: "hevc", rateControl: "ABR", videoKbps: 20000, audioKbps: 192)
        }
    }

    static func load(_ target: Target) -> EncoderSettings {
        let defaults = AppSettings.defaults
        func key(_ key: AppSettings.EncoderKey) -> String { AppSettings.key(target, key) }
        let base = Self.defaults(target)
        var settings = base
        settings.codec = defaults.string(forKey: key(.codec)) ?? base.codec
        settings.rateControl = defaults.string(forKey: key(.rateControl)) ?? base.rateControl
        settings.videoKbps = defaults.integer(forKey: key(.bitrate))
        settings.quality = defaults.integer(forKey: key(.quality))
        settings.limitBitrate = defaults.bool(forKey: key(.limitBitrate))
        settings.maxBitrateKbps = defaults.integer(forKey: key(.maxBitrate))
        settings.maxBitrateWindow = defaults.double(forKey: key(.maxBitrateWindow))
        settings.keyintSeconds = defaults.integer(forKey: key(.keyint))
        settings.profile = defaults.string(forKey: key(.profile)) ?? base.profile
        settings.bframes = defaults.bool(forKey: key(.bframes))
        settings.outputHeight = defaults.integer(forKey: key(.outputHeight))
        settings.audioKbps = defaults.integer(forKey: key(.audioBitrate))
        settings.heAAC = defaults.bool(forKey: key(.heAAC))
        return settings
    }

    static func stream(chzzk: Bool, canvasHeight: UInt32) -> EncoderSettings {
        let settings = load(.stream)
        return chzzk ? settings.forChzzk(canvasHeight: canvasHeight) : settings
    }

    func forChzzk(
        keyint: Int = max(AppSettings.defaults.integer(forKey: AppSettings.chzzkKeyint), 1), canvasHeight: UInt32
    ) -> EncoderSettings {
        var settings = self
        settings.codec = "h264"
        settings.rateControl = "CBR"
        settings.videoKbps = min(videoKbps, Chzzk.maxVideoKbps)
        settings.keyintSeconds = min(keyint, Chzzk.maxKeyint)
        settings.bframes = false
        settings.audioKbps = min(audioKbps, Chzzk.maxAudioKbps)
        // 치지직은 1920×1080까지 받는다. 캔버스가 더 크면 1080p로 줄여 보낸다
        let height = outputHeight > 0 ? min(outputHeight, Int(canvasHeight)) : Int(canvasHeight)
        if height > Chzzk.maxHeight { settings.outputHeight = Chzzk.maxHeight }
        return settings
    }

    /// 실제 출력 크기 (캔버스 비율, 짝수). 캔버스와 같으면 nil
    func outputSize(canvasWidth: UInt32, canvasHeight: UInt32) -> (width: UInt32, height: UInt32)? {
        guard outputHeight > 0, outputHeight < Int(canvasHeight), canvasHeight > 0 else { return nil }
        let height = UInt32(outputHeight / 2 * 2)
        let width = UInt32((Double(canvasWidth) * Double(height) / Double(canvasHeight) / 2).rounded()) * 2
        return width >= 16 && height >= 16 ? (width, height) : nil
    }

    func video(canvasWidth: UInt32, canvasHeight: UInt32) -> core_video_encoding {
        var video = core_video_encoding()
        video.codec = Int32(codec == "hevc" ? CORE_CODEC_HEVC.rawValue : CORE_CODEC_H264.rawValue)
        video.rate_control = Int32(
            rateControl == "CRF" ? CORE_RC_CRF.rawValue : rateControl == "ABR" ? CORE_RC_ABR.rawValue : CORE_RC_CBR.rawValue)
        video.bitrate_kbps = Int32(videoKbps)
        video.quality = Int32(quality)
        video.limit_bitrate = limitBitrate
        video.max_bitrate_kbps = Int32(maxBitrateKbps > 0 ? maxBitrateKbps : videoKbps)
        video.max_bitrate_window = maxBitrateWindow
        video.keyint_sec = Int32(keyintSeconds)
        video.profile = Int32(
            profile == "baseline"
                ? CORE_PROFILE_BASELINE.rawValue : profile == "main" ? CORE_PROFILE_MAIN.rawValue : CORE_PROFILE_HIGH.rawValue)
        video.bframes = bframes
        if let size = outputSize(canvasWidth: canvasWidth, canvasHeight: canvasHeight) {
            (video.width, video.height) = size
        }
        video.scale_type = Int32(AppSettings.defaults.integer(forKey: AppSettings.canvasScale))
        return video
    }

    var audio: core_audio_encoding {
        core_audio_encoding(bitrate_kbps: Int32(audioKbps), he_aac: heAAC && audioKbps <= 64)
    }

    /// 화면용 요약: "CBR 6000 kbps, 키프레임 2초, B프레임"
    var summary: String {
        let rate = rateControl == "CRF" ? "CRF 품질 \(quality)" : "\(rateControl) \(videoKbps) kbps"
        return "\(rate), 키프레임 \(keyintSeconds)초, \(bframes ? "B프레임" : "B프레임 없음")"
    }
}

/// 송출 연결 옵션 (P11)
enum StreamOptions {
    static func current() -> core_stream_options {
        let defaults = AppSettings.defaults
        return core_stream_options(
            dyn_bitrate: defaults.bool(forKey: AppSettings.streamDynBitrate),
            reconnect: defaults.bool(forKey: AppSettings.streamReconnect),
            retries: Int32(defaults.integer(forKey: AppSettings.streamRetries)),
            retry_sec: Int32(defaults.integer(forKey: AppSettings.streamRetrySeconds)),
            delay_sec: Int32(defaults.integer(forKey: AppSettings.streamDelay)))
    }
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
    case stream, record, canvas, display, faceTracking, about, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stream: "송출"
        case .record: "녹화"
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
            // 리플레이 버퍼는 녹화 페이지로 옮겼다 (P11)
            let saved: SettingsPage = savedPage == "replay" ? .record : SettingsPage(rawValue: savedPage) ?? .stream
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
        case .canvas: CanvasSettingsPage(core: core, outputs: outputs)
        case .display: DisplaySettingsPage()
        case .faceTracking: FaceLinkSettingsView()
        case .about: AboutSettingsPage()
        case .developer: DeveloperSettingsPage()
        }
    }
}

private let audioBitrates = [32, 48, 64, 96, 128, 160, 192, 256, 320]

private struct StreamSettingsPage: View {
    @ObservedObject var outputs: Outputs
    @ObservedObject private var youtube = YouTubeAccount.shared
    @ObservedObject private var core = Core.shared
    @AppStorage(AppSettings.streamServer) private var server = ""
    @AppStorage(AppSettings.streamMode) private var streamMode = "manual"
    @AppStorage(AppSettings.streamDynBitrate) private var dynBitrate = false
    @AppStorage(AppSettings.streamReconnect) private var reconnect = true
    @AppStorage(AppSettings.streamRetries) private var retries = 20
    @AppStorage(AppSettings.streamRetrySeconds) private var retrySeconds = 5
    @AppStorage(AppSettings.streamDelay) private var delay = 0
    @State private var streamKey = ""
    @State private var chzzkKey = ""

    private var srt: Bool { streamMode == "manual" && server.lowercased().hasPrefix("srt://") }

    var body: some View {
        Form {
            Section {
                Picker("방식", selection: $streamMode) {
                    Text("서버·스트림 키 입력").tag("manual")
                    Text("YouTube 계정").tag("youtube")
                    Text("치지직").tag("chzzk")
                }
                switch streamMode {
                case "youtube":
                    YouTubeAccountRows(account: youtube)
                case "chzzk":
                    LabeledContent("서버") {
                        Text(Chzzk.server).font(.footnote).textSelection(.enabled)
                    }
                    SecureField("스트림 키", text: $chzzkKey)
                        .onChange(of: chzzkKey) { _, key in Chzzk.keyStore.save(key) }
                    Link("스트림 키 받기 (치지직 스튜디오)", destination: Chzzk.keyPage)
                default:
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
                switch streamMode {
                case "youtube":
                    Text("YouTube 계정으로 로그인하면 송출할 때 스트림 키를 자동으로 받습니다. 로그인 정보는 Keychain에 저장합니다.")
                case "chzzk":
                    Text("치지직 스튜디오의 방송 설정에서 스트림 키를 복사해 넣으세요. 키는 Keychain에 저장합니다.")
                default:
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

            EncoderSection(target: .stream, chzzk: streamMode == "chzzk", footer: encodingFooter)
                .disabled(outputs.stats.streaming)

            Section {
                Toggle("끊기면 다시 연결", isOn: $reconnect)
                if reconnect {
                    Stepper("최대 \(retries)번", value: $retries, in: 1...100)
                    Stepper("\(retrySeconds)초 간격", value: $retrySeconds, in: 1...60)
                }
                Stepper(delay == 0 ? "송출 지연 없음" : "송출 지연 \(delay)초", value: $delay, in: 0...60)
                if !srt {
                    Toggle("네트워크가 막히면 비트레이트 낮추기", isOn: $dynBitrate)
                        .disabled(delay > 0)
                }
            } header: {
                Text("연결")
            } footer: {
                if delay > 0 && !srt {
                    Text("송출 지연을 쓰는 동안은 비트레이트 자동 조절이 꺼집니다. 지연은 화면을 그만큼 늦게 보냅니다 (스포일러·사고 방지).")
                } else if !srt {
                    Text("비트레이트 자동 조절은 보내는 속도가 밀리면 비디오 비트레이트를 잠시 낮췄다가 되돌립니다 (RTMP만).")
                } else {
                    Text("SRT는 자체 재전송을 쓰므로 비트레이트 자동 조절이 없습니다.")
                }
            }
            .disabled(outputs.stats.streaming)

            BroadcastLinkSection(mode: streamMode)

            BackgroundLiveSection()
        }
        .onAppear {
            streamKey = StreamKeyStore.load()
            chzzkKey = Chzzk.keyStore.load()
        }
    }

    private var encodingFooter: Text {
        switch streamMode {
        case "youtube":
            return Text("HEVC는 YouTube가 받습니다 (Enhanced RTMP).")
        case "chzzk":
            return chzzkFooter
        default:
            return Text("HEVC는 받는 플랫폼이 지원할 때만 쓰세요.")
        }
    }

    /// 치지직 권장값으로 실제 보낼 값
    private var chzzkFooter: Text {
        let encoding = EncoderSettings.stream(chzzk: true, canvasHeight: core.height)
        let size = encoding.outputSize(canvasWidth: core.width, canvasHeight: core.height)
        var text =
            "치지직 권장값으로 보냅니다: H.264, CBR, B프레임 없음, 비디오 최대 \(Chzzk.maxVideoKbps)·오디오 최대 \(Chzzk.maxAudioKbps) kbps, 1080p까지. 지금 설정으로는 비디오 \(encoding.videoKbps) kbps, 오디오 \(encoding.audioKbps) kbps, 키프레임 \(encoding.keyintSeconds)초"
        text += size.map { ", \($0.width)×\($0.height)로 줄여서." } ?? "."
        if core.fps > Chzzk.maxFPS + 0.01 {
            text += " 캔버스가 60 fps를 넘습니다. 치지직은 60 fps까지 받으니 캔버스를 60 이하로 바꾸세요."
        }
        return Text(text)
    }
}

/// 송출·녹화의 비디오·오디오 인코딩 (P11). 치지직이면 권장값으로 덮어쓰는 항목은 고정해 보인다
private struct EncoderSection: View {
    let target: EncoderSettings.Target
    var chzzk = false
    let footer: Text

    @ObservedObject private var core = Core.shared
    @AppStorage private var codec: String
    @AppStorage private var rateControl: String
    @AppStorage private var bitrate: Int
    @AppStorage private var quality: Int
    @AppStorage private var limitBitrate: Bool
    @AppStorage private var maxBitrate: Int
    @AppStorage private var maxBitrateWindow: Double
    @AppStorage private var keyint: Int
    @AppStorage private var profile: String
    @AppStorage private var bframes: Bool
    @AppStorage private var outputHeight: Int
    @AppStorage private var audioBitrate: Int
    @AppStorage private var heAAC: Bool
    @AppStorage(AppSettings.chzzkKeyint) private var chzzkKeyint = 1
    @State private var customHeight = false
    @State private var heightText = ""

    init(target: EncoderSettings.Target, chzzk: Bool = false, footer: Text) {
        self.target = target
        self.chzzk = chzzk
        self.footer = footer
        let base = EncoderSettings.defaults(target)
        func key(_ key: AppSettings.EncoderKey) -> String { AppSettings.key(target, key) }
        _codec = AppStorage(wrappedValue: base.codec, key(.codec))
        _rateControl = AppStorage(wrappedValue: base.rateControl, key(.rateControl))
        _bitrate = AppStorage(wrappedValue: base.videoKbps, key(.bitrate))
        _quality = AppStorage(wrappedValue: base.quality, key(.quality))
        _limitBitrate = AppStorage(wrappedValue: base.limitBitrate, key(.limitBitrate))
        _maxBitrate = AppStorage(wrappedValue: base.maxBitrateKbps, key(.maxBitrate))
        _maxBitrateWindow = AppStorage(wrappedValue: base.maxBitrateWindow, key(.maxBitrateWindow))
        _keyint = AppStorage(wrappedValue: base.keyintSeconds, key(.keyint))
        _profile = AppStorage(wrappedValue: base.profile, key(.profile))
        _bframes = AppStorage(wrappedValue: base.bframes, key(.bframes))
        _outputHeight = AppStorage(wrappedValue: 0, key(.outputHeight))
        _audioBitrate = AppStorage(wrappedValue: base.audioKbps, key(.audioBitrate))
        _heAAC = AppStorage(wrappedValue: false, key(.heAAC))
    }

    private var record: Bool { target == .record }
    private var rateControls: [String] { record ? ["ABR", "CBR", "CRF"] : ["CBR", "ABR"] }
    /// 고를 수 있는 출력 높이 (캔버스보다 작은 것만)
    private var heights: [Int] { [1440, 1080, 900, 720, 540, 480, 360].filter { $0 < Int(core.height) } }

    var body: some View {
        Section {
            if chzzk {
                LabeledContent("코덱", value: "H.264 (치지직)")
                LabeledContent("레이트 컨트롤", value: "CBR (치지직)")
            } else {
                Picker("코덱", selection: $codec) {
                    Text("H.264").tag("h264")
                    Text(record ? "HEVC" : "HEVC (Enhanced RTMP)").tag("hevc")
                }
                Picker("레이트 컨트롤", selection: $rateControl) {
                    ForEach(rateControls, id: \.self) { Text(Self.rateControlTitle($0)).tag($0) }
                }
            }
            if rateControl == "CRF" && !chzzk {
                LabeledContent("품질 \(quality)") {
                    Slider(value: Binding(get: { Double(quality) }, set: { quality = Int($0) }), in: 0...100, step: 1)
                        .frame(maxWidth: 260)
                }
            } else if record {
                Stepper("비디오 \(bitrate / 1000) Mbps", value: $bitrate, in: 5000...150000, step: 5000)
            } else {
                Stepper("비디오 \(bitrate) kbps", value: $bitrate, in: 1000...50000, step: 500)
            }
            if chzzk {
                Picker("키프레임 간격", selection: $chzzkKeyint) {
                    Text("1초 (권장)").tag(1)
                    Text("2초").tag(2)
                }
                LabeledContent("B프레임", value: "없음 (치지직)")
            } else {
                Picker("키프레임 간격", selection: $keyint) {
                    ForEach(1...10, id: \.self) { Text("\($0)초").tag($0) }
                }
                Toggle("B프레임", isOn: $bframes)
            }
            outputSizeRows
            Picker("오디오 (AAC)", selection: $audioBitrate) {
                ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
            }
            DisclosureGroup("고급") {
                if codec == "h264" || chzzk {
                    Picker("프로파일", selection: $profile) {
                        Text("High").tag("high")
                        Text("Main").tag("main")
                        Text("Baseline").tag("baseline")
                    }
                } else {
                    LabeledContent("프로파일", value: "Main")
                }
                if rateControl != "CBR" && !chzzk {
                    Toggle("최대 비트레이트 제한", isOn: $limitBitrate)
                    if limitBitrate {
                        Stepper(
                            "최대 \(maxBitrate > 0 ? maxBitrate : bitrate) kbps",
                            value: Binding(get: { maxBitrate > 0 ? maxBitrate : bitrate }, set: { maxBitrate = $0 }),
                            in: 500...200000, step: 500)
                        Stepper(
                            String(format: "%.1f초 동안", maxBitrateWindow), value: $maxBitrateWindow, in: 0.5...10,
                            step: 0.5)
                    }
                }
                Toggle("HE-AAC (64 kbps 이하)", isOn: $heAAC)
                    .disabled(audioBitrate > 64)
            }
        } header: {
            Text(record ? "Hybrid MP4" : "인코딩")
        } footer: {
            footer
        }
        .onAppear {
            customHeight = outputHeight > 0 && !heights.contains(outputHeight)
            heightText = customHeight ? "\(outputHeight)" : ""
        }
    }

    @ViewBuilder
    private var outputSizeRows: some View {
        Picker("출력 해상도", selection: heightTag) {
            Text("캔버스와 같게 (\(core.width)×\(core.height))").tag(0)
            ForEach(heights, id: \.self) { height in
                Text(sizeText(height)).tag(height)
            }
            Text("직접 입력…").tag(-1)
        }
        if customHeight {
            TextField("세로 픽셀 (예: 810)", text: $heightText)
                .keyboardType(.numberPad)
                .onChange(of: heightText) { _, text in
                    if let height = Int(text), height >= 16, height < Int(core.height) { outputHeight = height }
                }
            if let height = Int(heightText), height >= 16, height < Int(core.height) {
                LabeledContent("적용할 값", value: sizeText(height))
            } else if !heightText.isEmpty {
                Text("16 이상, 캔버스 높이(\(core.height))보다 작은 값을 넣으세요.").font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var heightTag: Binding<Int> {
        Binding(
            get: { customHeight ? -1 : (heights.contains(outputHeight) ? outputHeight : 0) },
            set: { tag in
                customHeight = tag == -1
                if tag >= 0 {
                    outputHeight = tag
                } else {
                    heightText = outputHeight > 0 ? "\(outputHeight)" : ""
                }
            })
    }

    private func sizeText(_ height: Int) -> String {
        let settings = EncoderSettings(outputHeight: height)
        guard let size = settings.outputSize(canvasWidth: core.width, canvasHeight: core.height) else { return "\(height)p" }
        return "\(size.width)×\(size.height)"
    }

    private static func rateControlTitle(_ rateControl: String) -> String {
        switch rateControl {
        case "ABR": "ABR (평균 비트레이트)"
        case "CRF": "CRF (품질 고정)"
        default: "CBR (고정 비트레이트)"
        }
    }
}

private struct RecordSettingsPage: View {
    @ObservedObject var outputs: Outputs
    @State private var pickingFolder = false
    @State private var folderName = RecordingFolder.displayName

    var body: some View {
        Form {
            EncoderSection(
                target: .record,
                footer: Text("녹화 중에 앱이 강제로 끝나도 파일을 살릴 수 있는 형식입니다. CRF는 비트레이트 대신 품질을 고정합니다. 리플레이 버퍼도 이 설정을 같이 씁니다.")
            )
            .disabled(outputs.stats.recording || outputs.stats.replay_active)

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
            .disabled(outputs.stats.recording)

            ReplaySection()
                .disabled(outputs.stats.replay_active)
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, RecordingFolder.remember(url) {
                folderName = RecordingFolder.displayName
            }
        }
    }
}

/// 리플레이 버퍼 길이: 목록 또는 직접 입력 ("90", "1:30", "2m", "1분 30초")
enum ReplayDuration {
    static let presets = [10, 15, 30, 60, 120, 300]
    static let range = 1...3600

    static func parse(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        var seconds: Int?
        let colon = text.split(separator: ":", omittingEmptySubsequences: false)
        if colon.count == 2, let minutes = Int(colon[0]), let rest = Int(colon[1]), (0..<60).contains(rest) {
            seconds = minutes * 60 + rest
        } else if let value = Int(text) {
            seconds = value
        } else {
            // "2m", "90s", "1m30s", "2분", "90초", "1분 30초"
            var total = 0
            var number = ""
            var matched = false
            for character in text.replacingOccurrences(of: " ", with: "") {
                if character.isNumber {
                    number.append(character)
                } else if let value = Int(number), "m분".contains(character) || "s초".contains(character) {
                    total += "m분".contains(character) ? value * 60 : value
                    number = ""
                    matched = true
                } else {
                    return nil
                }
            }
            seconds = matched && number.isEmpty ? total : nil
        }
        return seconds.flatMap { range.contains($0) ? $0 : nil }
    }

    static func text(_ seconds: Int) -> String {
        let (minutes, rest) = (seconds / 60, seconds % 60)
        if minutes == 0 { return "\(rest)초" }
        return rest == 0 ? "\(minutes)분" : "\(minutes)분 \(rest)초"
    }
}

private struct ReplaySection: View {
    @AppStorage(AppSettings.replaySeconds) private var replaySeconds = 30
    @AppStorage(AppSettings.replayMaxMB) private var maxMB = 2048
    @State private var custom = false
    @State private var customText = ""

    var body: some View {
        Section {
            Picker("길이", selection: tag) {
                ForEach(ReplayDuration.presets, id: \.self) { Text(ReplayDuration.text($0)).tag($0) }
                Text("직접 입력…").tag(-1)
            }
            if custom {
                TextField("예: 90, 1:30, 2분", text: $customText)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .onChange(of: customText) { _, text in
                        if let seconds = ReplayDuration.parse(text) { replaySeconds = seconds }
                    }
                if let seconds = ReplayDuration.parse(customText) {
                    LabeledContent("적용할 값", value: ReplayDuration.text(seconds))
                } else if !customText.isEmpty {
                    Text("1초~60분 사이로 넣으세요 (90, 1:30, 2분, 1분 30초).").font(.footnote).foregroundStyle(.red)
                }
            }
            Stepper("메모리 최대 \(maxMB) MB", value: $maxMB, in: 256...8192, step: 256)
            Text(estimate).font(.footnote).foregroundStyle(estimateTooBig ? .orange : .secondary)
        } header: {
            Text("리플레이 버퍼")
        } footer: {
            Text("켜 두면 마지막 장면을 메모리에 두었다가 \"리플레이 저장\"을 누를 때 앱의 Recordings 폴더에 MP4로 저장합니다. 위의 녹화 인코딩을 같이 씁니다.")
        }
        .onAppear {
            custom = !ReplayDuration.presets.contains(replaySeconds)
            customText = custom ? "\(replaySeconds)" : ""
        }
    }

    private var tag: Binding<Int> {
        Binding(
            get: { custom ? -1 : replaySeconds },
            set: { tag in
                custom = tag == -1
                if tag > 0 {
                    replaySeconds = tag
                } else {
                    customText = "\(replaySeconds)"
                }
            })
    }

    /// 녹화 비트레이트로 어림한 메모리
    private var estimatedMB: Int? {
        let encoding = EncoderSettings.load(.record)
        guard encoding.rateControl != "CRF" else { return nil }
        return (encoding.videoKbps + encoding.audioKbps) * replaySeconds / 8000
    }

    private var estimateTooBig: Bool { (estimatedMB ?? 0) > maxMB }

    private var estimate: String {
        guard let estimatedMB else { return "CRF(품질 고정)는 크기를 미리 알 수 없습니다. 최대를 넘으면 오래된 부분부터 버립니다." }
        if estimateTooBig {
            return "예상 \(estimatedMB) MB로 최대를 넘습니다. 앞부분이 잘려 \(ReplayDuration.text(max(1, replaySeconds * maxMB / max(estimatedMB, 1)))) 정도만 남습니다."
        }
        return "예상 메모리 약 \(estimatedMB) MB (녹화 비트레이트 기준)"
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

/// 캔버스 색 (P11): enum video_colorspace·video_range_type의 값. 8비트 SDR만
struct CanvasColor: Hashable {
    var colorSpace = 2  // 1 Rec.601, 2 Rec.709, 3 sRGB
    var range = 1  // 1 제한, 2 전체

    static let spaces: [(name: String, title: String, value: Int)] = [
        ("709", "Rec.709", 2), ("601", "Rec.601", 1), ("srgb", "sRGB", 3),
    ]

    init(colorSpace: Int = 2, range: Int = 1) {
        self.colorSpace = Self.spaces.contains { $0.value == colorSpace } ? colorSpace : 2
        self.range = range == 2 ? 2 : 1
    }

    var logText: String {
        "\(Self.spaces.first { $0.value == colorSpace }?.name ?? "709") \(range == 2 ? "full" : "partial")"
    }
}

private struct CanvasSettingsPage: View {
    @ObservedObject var core: Core
    @ObservedObject var outputs: Outputs
    @State private var size = CanvasSize(width: 1920, height: 1080)
    /// 목록에서 고른 값 ("분자/분모") 또는 "custom"
    @State private var rateTag = "60/1"
    @State private var customText = ""
    @State private var color = CanvasColor()
    @State private var canvasMessage = ""
    @AppStorage(AppSettings.canvasScale) private var scaleType = 2
    @AppStorage(AppSettings.audioSampleRate) private var sampleRate = 48000
    @AppStorage(AppSettings.audioChannels) private var channels = 2
    @AppStorage(AppSettings.audioFixedBuffering) private var fixedBuffering = true

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
                Picker("색 공간", selection: $color.colorSpace) {
                    ForEach(CanvasColor.spaces, id: \.value) { Text($0.title).tag($0.value) }
                }
                Picker("색 범위", selection: $color.range) {
                    Text("제한 (16–235)").tag(1)
                    Text("전체 (0–255)").tag(2)
                }
                Button("적용") {
                    guard let frameRate else { return }
                    canvasMessage =
                        core.applyCanvas(width: size.width, height: size.height, frameRate: frameRate, color: color)
                        ? "바꿨습니다. 맞지 않는 소스는 ⋯ 메뉴의 '화면에 맞추기'를 쓰세요."
                        : "바꾸지 못했습니다. 녹화·송출을 멈춘 뒤 다시 해 보세요."
                }
                .disabled(
                    outputs.stats.recording || outputs.stats.streaming || outputs.stats.replay_active || frameRate == nil
                        || (size == CanvasSize(width: core.width, height: core.height) && frameRate == core.frameRate
                            && color == core.color))
                if !canvasMessage.isEmpty {
                    Text(canvasMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                if let frameRate, frameRate.fps > 60.01 {
                    Text("녹화·송출 중에는 바꿀 수 없습니다. 송출 플랫폼 대부분은 60 fps까지 받습니다.")
                } else if color != CanvasColor() {
                    Text("녹화·송출 중에는 바꿀 수 없습니다. 송출은 Rec.709·제한 범위를 권장합니다 (플랫폼 대부분이 그렇게 가정합니다).")
                } else {
                    Text("녹화·송출 중에는 바꿀 수 없습니다. 29.97·59.94처럼 방송 장비와 맞출 값은 분수(30000/1001)로 정확히 들어갑니다.")
                }
            }

            Section {
                Picker("스케일 필터", selection: $scaleType) {
                    Text("바이리니어 (빠름)").tag(3)
                    Text("바이큐빅").tag(2)
                    Text("란초스 (선명)").tag(4)
                    Text("영역 (축소에 좋음)").tag(5)
                }
            } header: {
                Text("출력 크기 줄이기")
            } footer: {
                Text("송출·녹화의 출력 해상도를 캔버스보다 작게 골랐을 때 GPU가 줄이는 방법입니다. 다음 송출·녹화부터 적용됩니다.")
            }

            Section {
                Picker("샘플레이트", selection: $sampleRate) {
                    Text("48 kHz").tag(48000)
                    Text("44.1 kHz").tag(44100)
                }
                Picker("채널", selection: $channels) {
                    Text("스테레오").tag(2)
                    Text("모노").tag(1)
                }
                Picker("버퍼링", selection: $fixedBuffering) {
                    Text("고정 128ms (권장)").tag(true)
                    Text("자동 늘림 (최대 960ms)").tag(false)
                }
            } header: {
                Text("오디오")
            } footer: {
                if core.audioFormat != (sampleRate, channels) || core.audioFixedBuffering != fixedBuffering {
                    Text("앱을 다시 열면 적용됩니다.").foregroundStyle(.orange)
                } else {
                    Text("바꾸면 앱을 다시 열 때 적용됩니다. 자동 늘림은 소리가 잠깐 늦게 오면 지연이 늘어난 채로 남을 수 있습니다.")
                }
            }
        }
        .onAppear {
            color = core.color
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
