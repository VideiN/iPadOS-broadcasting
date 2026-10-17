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
    static let canvasFPS = "canvasFPS"
    static let previewEnabled = "previewEnabled"  // 끄면 프리뷰 디스플레이를 없앤다 (출력용 캔버스는 계속 그린다)

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
        ])
    }

    static var defaults: UserDefaults { .standard }
}

/// 스트림 키는 Keychain에 둔다. LiveContainer 게스트에서 Keychain을 못 쓰면 UserDefaults에 둔다.
enum StreamKeyStore {
    private static let service = "io.github.videin.broadcast.stream-key"
    private static let fallbackKey = "streamKey"

    static func load() -> String {
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

    static func save(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)

        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)

        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            appLog("keychain unavailable (\(status)), stream key kept in app settings")
            UserDefaults.standard.set(key, forKey: fallbackKey)
        }
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

struct SettingsView: View {
    @ObservedObject var core: Core
    @ObservedObject var outputs: Outputs

    @AppStorage(AppSettings.streamServer) private var server = ""
    @AppStorage(AppSettings.streamCodec) private var streamCodec = "h264"
    @AppStorage(AppSettings.streamBitrate) private var streamBitrate = 6000
    @AppStorage(AppSettings.streamAudioBitrate) private var streamAudioBitrate = 160
    @AppStorage(AppSettings.recordCodec) private var recordCodec = "hevc"
    @AppStorage(AppSettings.recordBitrate) private var recordBitrate = 20000
    @AppStorage(AppSettings.recordAudioBitrate) private var recordAudioBitrate = 192

    @State private var streamKey = ""
    @State private var canvas = CanvasChoice(width: 1920, height: 1080, fps: 60)
    @State private var pickingFolder = false
    @State private var folderName = RecordingFolder.displayName
    @State private var canvasMessage = ""
    @Environment(\.dismiss) private var dismiss

    struct CanvasChoice: Hashable {
        var width: UInt32
        var height: UInt32
        var fps: UInt32
    }

    private let resolutions: [(String, UInt32, UInt32)] = [
        ("1280×720", 1280, 720), ("1920×1080", 1920, 1080), ("2560×1440", 2560, 1440), ("3840×2160", 3840, 2160),
    ]
    private let audioBitrates = [96, 128, 160, 192, 256, 320]

    var body: some View {
        NavigationStack {
            Form {
                streamSection
                recordSection
                canvasSection

                Section("정보") {
                    NavigationLink("진단과 로그") { DiagnosticsView() }
                    NavigationLink("오픈소스 라이선스") { LicensesView() }
                    LabeledContent("버전", value: appVersion)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .onAppear {
            streamKey = StreamKeyStore.load()
            canvas = CanvasChoice(width: core.width, height: core.height, fps: core.fps)
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, RecordingFolder.remember(url) {
                folderName = RecordingFolder.displayName
            }
        }
    }

    private var streamSection: some View {
        Section {
            TextField("rtmp://… 또는 rtmps://…", text: $server)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("스트림 키", text: $streamKey)
                .onChange(of: streamKey) { _, key in StreamKeyStore.save(key) }
            Picker("코덱", selection: $streamCodec) {
                Text("H.264").tag("h264")
                Text("HEVC (Enhanced RTMP)").tag("hevc")
            }
            Stepper("비디오 \(streamBitrate) kbps (CBR)", value: $streamBitrate, in: 1000...50000, step: 500)
            Picker("오디오 (AAC)", selection: $streamAudioBitrate) {
                ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
            }
        } header: {
            Text("송출")
        } footer: {
            Text(
                "예: rtmp://live.twitch.tv/app, rtmps://a.rtmps.youtube.com:443/live2. HEVC는 받는 플랫폼이 지원할 때만 쓰세요. 스트림 키는 Keychain에 저장합니다."
            )
        }
        .disabled(outputs.stats.streaming)
    }

    private var recordSection: some View {
        Section {
            Picker("코덱", selection: $recordCodec) {
                Text("HEVC").tag("hevc")
                Text("H.264").tag("h264")
            }
            Stepper("비디오 \(recordBitrate / 1000) Mbps", value: $recordBitrate, in: 5000...150000, step: 5000)
            Picker("오디오 (AAC)", selection: $recordAudioBitrate) {
                ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
            }
            LabeledContent("저장 위치", value: folderName)
            Button("다른 폴더 선택… (외장 저장장치 등)") { pickingFolder = true }
            if UserDefaults.standard.data(forKey: AppSettings.recordFolderBookmark) != nil {
                Button("앱 문서 폴더로 되돌리기") {
                    RecordingFolder.forget()
                    folderName = RecordingFolder.displayName
                }
            }
        } header: {
            Text("녹화 (Hybrid MP4)")
        } footer: {
            Text("녹화 중에 앱이 강제로 끝나도 파일을 살릴 수 있는 형식입니다.")
        }
        .disabled(outputs.stats.recording)
    }

    private var canvasSection: some View {
        Section {
            Picker("해상도", selection: $canvas) {
                ForEach(resolutions, id: \.0) { resolution in
                    Text(resolution.0).tag(CanvasChoice(width: resolution.1, height: resolution.2, fps: canvas.fps))
                }
            }
            Picker("프레임", selection: $canvas.fps) {
                Text("30 fps").tag(UInt32(30))
                Text("60 fps").tag(UInt32(60))
            }
            Button("적용") {
                canvasMessage = core.applyCanvas(width: canvas.width, height: canvas.height, fps: canvas.fps)
                    ? "바꿨습니다. 맞지 않는 소스는 ⋯ 메뉴의 '화면에 맞추기'를 쓰세요."
                    : "바꾸지 못했습니다. 녹화·송출을 멈춘 뒤 다시 해 보세요."
            }
            .disabled(
                outputs.stats.recording || outputs.stats.streaming
                    || canvas == CanvasChoice(width: core.width, height: core.height, fps: core.fps))
            if !canvasMessage.isEmpty {
                Text(canvasMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("캔버스")
        } footer: {
            Text("녹화·송출 중에는 바꿀 수 없습니다.")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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
        Entry(file: "mbedtls", title: "Mbed TLS", license: "Apache-2.0 또는 GPL-2.0-or-later"),
        Entry(file: "jansson", title: "Jansson", license: "MIT"),
        Entry(file: "libcaption", title: "libcaption", license: "MIT"),
        Entry(file: "simde", title: "SIMDe", license: "MIT"),
        Entry(file: "uthash", title: "uthash", license: "BSD-1-Clause"),
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
