import AuthenticationServices
import CryptoKit
import SwiftUI

/// 유튜브 계정 (P8): 로그인해서 스트림 키를 받고, 송출할 때 새 방송을 만든다.
///
/// OAuth 2.0 + PKCE, 비밀값이 없는 iOS 유형 클라이언트. 클라이언트 ID는 사용자가 자기 Google Cloud 프로젝트에서
/// 만들어 넣는다 (PC OBS의 ID는 OBS 프로젝트 것이라 쓸 수 없고, 공개 저장소의 빌드에 ID를 넣지 않는다).
/// 갱신 토큰은 Keychain, 액세스 토큰은 메모리에만 둔다. 토큰은 로그에 남기지 않는다.
final class YouTubeAccount: ObservableObject {
    static let shared = YouTubeAccount()

    static let scope = "https://www.googleapis.com/auth/youtube"
    /// 이 앱이 만들고 다시 쓰는 스트림 (스트림 키 하나)
    static let streamTitle = "Broadcast (iPad)"

    struct Endpoints {
        var auth = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var token = URL(string: "https://oauth2.googleapis.com/token")!
        var revoke = URL(string: "https://oauth2.googleapis.com/revoke")!
        var api = URL(string: "https://www.googleapis.com/youtube/v3")!
    }

    /// 로그인 창에 넘길 것과 돌아왔을 때 맞춰 볼 것
    struct LoginRequest {
        let url: URL
        let callbackScheme: String
        let redirectURI: String
        let state: String
        let verifier: String
        let clientID: String
    }

    struct StreamTarget {
        let server: String
        let key: String
        let broadcastID: String?
    }

    @Published private(set) var loggedIn = false
    @Published private(set) var channelTitle = ""
    /// 로그인 마무리(토큰 교환·채널 조회) 중
    @Published var busy = false
    /// 마지막 오류 (설정 화면에 보인다)
    @Published var message = ""
    /// 마지막으로 만든 방송 (P7 채팅이 쓴다)
    @Published private(set) var broadcastID: String?

    private var endpoints = Endpoints()
    private let refreshItem = SecretItem(
        service: "io.github.videin.broadcast.youtube-refresh-token", fallbackKey: "youtubeRefreshToken")
    /// CI는 Keychain을 건드리지 않는다
    private var memoryOnly = false
    private var memoryRefreshToken = ""

    private var accessToken = ""
    private var accessExpiry = Date.distantPast

    private init() {
        loggedIn = !refreshToken.isEmpty
        channelTitle = AppSettings.defaults.string(forKey: AppSettings.youtubeChannelTitle) ?? ""
    }

    var clientID: String {
        (AppSettings.defaults.string(forKey: AppSettings.youtubeClientID) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// iOS 유형 클라이언트 ID: "<숫자>-<영숫자>.apps.googleusercontent.com"
    static func isValidClientID(_ id: String) -> Bool {
        id.range(of: #"^[0-9]+-[0-9A-Za-z_]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil
    }

    private var refreshToken: String {
        get { memoryOnly ? memoryRefreshToken : refreshItem.load() }
        set {
            if memoryOnly {
                memoryRefreshToken = newValue
            } else {
                refreshItem.save(newValue)
            }
        }
    }

    // MARK: 로그인

    func makeLoginRequest() throws -> LoginRequest {
        let clientID = clientID
        guard Self.isValidClientID(clientID) else {
            throw YouTubeError("OAuth 클라이언트 ID가 올바르지 않습니다. …apps.googleusercontent.com 형식의 iOS 클라이언트 ID를 넣으세요.")
        }

        // 리디렉션은 클라이언트 ID를 뒤집은 스킴 (iOS 유형 클라이언트의 규칙)
        let prefix = String(clientID.dropLast(".apps.googleusercontent.com".count))
        let scheme = "com.googleusercontent.apps.\(prefix)"
        let redirectURI = "\(scheme):/oauth2redirect"
        let verifier = Self.randomString(64)
        let state = Self.randomString(24)

        var components = URLComponents(url: endpoints.auth, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return LoginRequest(
            url: components.url!, callbackScheme: scheme, redirectURI: redirectURI, state: state, verifier: verifier,
            clientID: clientID)
    }

    /// 로그인 창이 돌려준 주소로 마무리: 코드 → 토큰 → 채널 이름
    func finishLogin(callback: URL, request: LoginRequest) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard value("state") == request.state else { throw YouTubeError("로그인 응답이 맞지 않습니다. 다시 시도하세요.") }
        if let error = value("error") {
            throw YouTubeError(error == "access_denied" ? "로그인을 취소했거나 권한을 허용하지 않았습니다." : "로그인 실패: \(error)")
        }
        guard let code = value("code") else { throw YouTubeError("로그인 응답에 코드가 없습니다.") }

        let token = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "client_id": request.clientID,
            "redirect_uri": request.redirectURI, "code_verifier": request.verifier,
        ])
        guard let refresh = token["refresh_token"] as? String, !refresh.isEmpty else {
            throw YouTubeError("Google이 갱신 토큰을 주지 않았습니다. 클라이언트 유형이 iOS인지 확인하세요.")
        }
        refreshToken = refresh
        if let access = token["access_token"] as? String {
            accessToken = access
            accessExpiry = Date().addingTimeInterval((token["expires_in"] as? Double) ?? 3600)
        }
        appLog("youtube: logged in")
        await publish { $0.loggedIn = true }
        try await refreshChannel()
    }

    func logout() {
        let token = refreshToken
        refreshToken = ""
        accessToken = ""
        accessExpiry = .distantPast
        AppSettings.defaults.removeObject(forKey: AppSettings.youtubeChannelTitle)
        AppSettings.defaults.removeObject(forKey: AppSettings.youtubeStreamID)
        loggedIn = false
        channelTitle = ""
        message = ""
        appLog("youtube: logged out")

        // 토큰을 Google에서도 무효로 (실패해도 이 기기에서는 이미 지웠다)
        guard !token.isEmpty else { return }
        var request = URLRequest(url: endpoints.revoke)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": token])
        URLSession.shared.dataTask(with: request).resume()
    }

    func refreshChannel() async throws {
        let result = try await api("GET", "channels", query: ["part": "snippet", "mine": "true"])
        let items = result["items"] as? [[String: Any]] ?? []
        guard let snippet = items.first?["snippet"] as? [String: Any], let title = snippet["title"] as? String else {
            throw YouTubeError("이 Google 계정에 YouTube 채널이 없습니다.")
        }
        AppSettings.defaults.set(title, forKey: AppSettings.youtubeChannelTitle)
        await publish { $0.channelTitle = title }
    }

    // MARK: 방송 준비

    /// 송출할 주소와 키. "새 방송 만들기"면 방송을 만들어 이 앱의 스트림에 연결한다 (자동 시작·종료)
    func prepareStream() async throws -> StreamTarget {
        let defaults = AppSettings.defaults
        let stream = try await ourStream(defaultOnly: defaults.string(forKey: AppSettings.youtubeBroadcastMode) == "key")
        guard let cdn = stream["cdn"] as? [String: Any], let ingestion = cdn["ingestionInfo"] as? [String: Any],
            let key = ingestion["streamName"] as? String,
            let server = (ingestion["rtmpsIngestionAddress"] as? String) ?? (ingestion["ingestionAddress"] as? String)
        else { throw YouTubeError("스트림 정보에 수신 주소가 없습니다.") }

        guard defaults.string(forKey: AppSettings.youtubeBroadcastMode) != "key", let streamID = stream["id"] as? String
        else {
            appLog("youtube: streaming with the stream key only")
            return StreamTarget(server: server, key: key, broadcastID: nil)
        }

        // 제목에 < > 는 쓸 수 없다
        let title = (defaults.string(forKey: AppSettings.youtubeTitle) ?? "")
            .replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let broadcast = try await api(
            "POST", "liveBroadcasts", query: ["part": "snippet,status,contentDetails"],
            body: [
                "snippet": [
                    "title": String((title.isEmpty ? "라이브 방송" : title).prefix(100)),
                    "description": String((defaults.string(forKey: AppSettings.youtubeDescription) ?? "").prefix(5000)),
                    "scheduledStartTime": ISO8601DateFormatter().string(from: Date()),
                ],
                "status": [
                    "privacyStatus": defaults.string(forKey: AppSettings.youtubePrivacy) ?? "unlisted",
                    "selfDeclaredMadeForKids": false,
                ],
                "contentDetails": [
                    "enableAutoStart": true,
                    "enableAutoStop": true,
                    "latencyPreference": defaults.string(forKey: AppSettings.youtubeLatency) ?? "normal",
                    "monitorStream": ["enableMonitorStream": false],
                ],
            ])
        guard let id = broadcast["id"] as? String else { throw YouTubeError("방송을 만들었지만 ID가 없습니다.") }

        _ = try await api("POST", "liveBroadcasts/bind", query: ["id": id, "streamId": streamID, "part": "id,contentDetails"])
        appLog("youtube: broadcast \(id) created and bound")
        await publish { $0.broadcastID = id }
        return StreamTarget(server: server, key: key, broadcastID: id)
    }

    /// "스트림 키만"이면 채널의 기본 스트림, 아니면 이 앱이 만든 재사용 스트림 (없으면 만든다)
    private func ourStream(defaultOnly: Bool) async throws -> [String: Any] {
        let list = try await api(
            "GET", "liveStreams", query: ["part": "id,snippet,cdn,contentDetails,status", "mine": "true", "maxResults": "50"])
        let streams = list["items"] as? [[String: Any]] ?? []

        if defaultOnly {
            let preferred = streams.first { ($0["snippet"] as? [String: Any])?["isDefaultStream"] as? Bool == true }
            guard let stream = preferred ?? streams.first else {
                throw YouTubeError("채널에 스트림 키가 없습니다. YouTube Studio에서 라이브를 한 번 열거나 \"새 방송 만들기\"를 쓰세요.")
            }
            return stream
        }

        let saved = AppSettings.defaults.string(forKey: AppSettings.youtubeStreamID)
        if let stream = streams.first(where: {
            ($0["id"] as? String) == saved || (($0["snippet"] as? [String: Any])?["title"] as? String) == Self.streamTitle
        }) {
            AppSettings.defaults.set(stream["id"] as? String, forKey: AppSettings.youtubeStreamID)
            return stream
        }

        let created = try await api(
            "POST", "liveStreams", query: ["part": "id,snippet,cdn,contentDetails,status"],
            body: [
                "snippet": ["title": Self.streamTitle, "description": "iPad 방송 앱이 만든 스트림"],
                "cdn": ["ingestionType": "rtmp", "resolution": "variable", "frameRate": "variable"],
                "contentDetails": ["isReusable": true],
            ])
        AppSettings.defaults.set(created["id"] as? String, forKey: AppSettings.youtubeStreamID)
        appLog("youtube: created the app's stream")
        return created
    }

    // MARK: 토큰과 API

    private func validAccessToken() async throws -> String {
        if !accessToken.isEmpty && accessExpiry.timeIntervalSinceNow > 60 {
            return accessToken
        }
        let refresh = refreshToken
        guard !refresh.isEmpty else { throw YouTubeError("YouTube에 로그인하세요.") }

        let token = try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
        ])
        guard let access = token["access_token"] as? String else { throw YouTubeError("토큰 응답이 올바르지 않습니다.") }
        accessToken = access
        accessExpiry = Date().addingTimeInterval((token["expires_in"] as? Double) ?? 3600)
        return access
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        appLog("youtube: token \(fields["grant_type"] ?? "") \(status)")
        guard status == 200 else {
            let error = json["error"] as? String ?? "HTTP \(status)"
            if error == "invalid_grant" && fields["grant_type"] == "refresh_token" {
                // 갱신 토큰이 무효 (비밀번호 변경, 접근 해제, 테스트 상태 앱의 7일 만료 등)
                await publish { $0.logout() }
                throw YouTubeError("YouTube 로그인이 만료되었습니다. 다시 로그인하세요.")
            }
            if error == "invalid_client" || error == "unauthorized_client" {
                throw YouTubeError("OAuth 클라이언트 ID가 맞지 않습니다 (\(error)). iOS 유형 클라이언트인지 확인하세요.")
            }
            throw YouTubeError("토큰 요청 실패: \(json["error_description"] as? String ?? error)")
        }
        return json
    }

    /// YouTube Data API 호출. 401이면 토큰을 한 번 새로 받아 다시 보낸다
    @discardableResult
    func api(_ method: String, _ path: String, query: [String: String], body: [String: Any]? = nil) async throws
        -> [String: Any]
    {
        for attempt in 0..<2 {
            let token = try await validAccessToken()
            var components = URLComponents(
                url: endpoints.api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            appLog("youtube: \(method) \(path) \(status)")
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

            if status == 401 && attempt == 0 {
                accessToken = ""
                continue
            }
            guard (200..<300).contains(status) else { throw Self.apiError(status: status, json: json) }
            return json
        }
        throw YouTubeError("YouTube 로그인이 만료되었습니다. 다시 로그인하세요.")
    }

    private static func apiError(status: Int, json: [String: Any]) -> YouTubeError {
        let error = json["error"] as? [String: Any]
        let reasons = ((error?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
        let message = error?["message"] as? String ?? "HTTP \(status)"

        if reasons.contains("liveStreamingNotEnabled") {
            return YouTubeError("이 채널은 라이브 스트리밍이 켜져 있지 않습니다. YouTube Studio에서 사용 설정하세요 (처음엔 최대 24시간 걸림).")
        }
        if reasons.contains("quotaExceeded") || reasons.contains("rateLimitExceeded") {
            return YouTubeError("오늘 YouTube API 사용량을 다 썼습니다. 내일 다시 하거나 스트림 키를 직접 넣으세요.")
        }
        if reasons.contains("accessNotConfigured") || message.contains("has not been used") || message.contains("disabled") {
            return YouTubeError("Google Cloud 프로젝트에서 YouTube Data API v3를 사용 설정하세요.")
        }
        if reasons.contains("insufficientPermissions") || status == 403 {
            return YouTubeError("권한이 없습니다. 로그인할 때 YouTube 계정 관리 권한을 허용했는지 확인하세요. (\(message))")
        }
        return YouTubeError("YouTube 요청 실패 (\(status)): \(message)")
    }

    // MARK: 도우미

    private func publish(_ change: @escaping (YouTubeAccount) -> Void) async {
        await MainActor.run { change(self) }
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters[Int(generator.next(upperBound: UInt(characters.count)))] })
    }

    /// PKCE S256: base64url(SHA256(verifier)), 패딩 없음
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }

    // MARK: CI

    /// CI용 (`-autotest-youtube <mock 주소>`): mock 서버로 로그인 흐름 전체(인증 주소 → 콜백 → 교환)를 돌리고
    /// "새 방송 만들기"로 송출 주소를 받는다. 토큰은 Keychain이 아니라 메모리에 둔다 (설정은 CI 시뮬레이터라 덮어쓴다).
    func runAutotest(base: String) async throws -> StreamTarget {
        guard let url = URL(string: base) else { throw YouTubeError("mock 주소가 올바르지 않습니다") }
        memoryOnly = true
        endpoints = Endpoints(
            auth: url.appendingPathComponent("o/oauth2/v2/auth"), token: url.appendingPathComponent("token"),
            revoke: url.appendingPathComponent("revoke"), api: url.appendingPathComponent("youtube/v3"))
        AppSettings.defaults.set("123456-autotest.apps.googleusercontent.com", forKey: AppSettings.youtubeClientID)
        AppSettings.defaults.set("new", forKey: AppSettings.youtubeBroadcastMode)
        AppSettings.defaults.set("CI <시험> 방송", forKey: AppSettings.youtubeTitle)
        AppSettings.defaults.set("unlisted", forKey: AppSettings.youtubePrivacy)
        AppSettings.defaults.removeObject(forKey: AppSettings.youtubeStreamID)

        // 로그인 창 대신 mock의 인증 주소를 직접 열고, 돌려준 콜백 주소를 그대로 처리한다
        let request = try makeLoginRequest()
        let (data, _) = try await URLSession.shared.data(from: request.url)
        guard let callback = URL(string: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
            callback.scheme == request.callbackScheme
        else { throw YouTubeError("mock 콜백이 올바르지 않습니다") }
        try await finishLogin(callback: callback, request: request)
        appLog("youtube autotest: logged in as \(channelTitle)")

        return try await prepareStream()
    }
}

struct YouTubeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 설정 화면

/// 송출 칸의 "YouTube 계정" 부분: 클라이언트 ID, 로그인/로그아웃
struct YouTubeAccountRows: View {
    @ObservedObject var account: YouTubeAccount
    @AppStorage(AppSettings.youtubeClientID) private var clientID = ""
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        if account.loggedIn {
            LabeledContent("채널", value: account.channelTitle.isEmpty ? "확인 중…" : account.channelTitle)
            Button("로그아웃", role: .destructive) { account.logout() }
        } else {
            TextField("OAuth 클라이언트 ID (…apps.googleusercontent.com)", text: $clientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            NavigationLink("설정 방법") { YouTubeSetupGuide() }
            Button {
                login()
            } label: {
                HStack {
                    Label("Google 계정으로 로그인", systemImage: "person.crop.circle.badge.checkmark")
                    if account.busy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(account.busy || !YouTubeAccount.isValidClientID(clientID.trimmingCharacters(in: .whitespaces)))
        }
        if !account.message.isEmpty {
            Text(account.message).font(.footnote).foregroundStyle(.red)
        }
    }

    private func login() {
        account.message = ""
        Task { @MainActor in
            do {
                let request = try account.makeLoginRequest()
                let callback = try await webAuthenticationSession.authenticate(
                    using: request.url, callbackURLScheme: request.callbackScheme, preferredBrowserSession: .shared)
                account.busy = true
                try await account.finishLogin(callback: callback, request: request)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // 사용자가 창을 닫음
            } catch {
                account.message = error.localizedDescription
                appLog("youtube: login failed: \(error.localizedDescription)")
            }
            account.busy = false
        }
    }
}

/// 로그인했을 때 보이는 방송 설정
struct YouTubeBroadcastSection: View {
    @AppStorage(AppSettings.youtubeBroadcastMode) private var mode = "new"
    @AppStorage(AppSettings.youtubeTitle) private var title = "라이브 방송"
    @AppStorage(AppSettings.youtubeDescription) private var description = ""
    @AppStorage(AppSettings.youtubePrivacy) private var privacy = "unlisted"
    @AppStorage(AppSettings.youtubeLatency) private var latency = "normal"

    var body: some View {
        Section {
            Picker("방송", selection: $mode) {
                Text("새 방송 만들기").tag("new")
                Text("스트림 키만").tag("key")
            }
            if mode == "new" {
                TextField("제목", text: $title)
                TextField("설명", text: $description, axis: .vertical)
                    .lineLimit(2...6)
                Picker("공개 범위", selection: $privacy) {
                    Text("공개").tag("public")
                    Text("일부 공개").tag("unlisted")
                    Text("비공개").tag("private")
                }
                Picker("지연 시간", selection: $latency) {
                    Text("보통").tag("normal")
                    Text("낮음").tag("low")
                    Text("매우 낮음").tag("ultraLow")
                }
            }
        } header: {
            Text("YouTube 방송")
        } footer: {
            Text(
                mode == "new"
                    ? "송출을 누르면 이 내용으로 새 방송을 만들고, 영상이 들어가면 자동으로 시작해 송출을 멈추면 자동으로 끝납니다. 방송 하나에 YouTube API 사용량이 약 5 단위 듭니다 (하루 10,000)."
                    : "채널의 기본 스트림 키로 보냅니다. 제목·공개 범위 등은 YouTube Studio 설정을 그대로 씁니다.")
        }
    }
}

/// Google Cloud에서 OAuth 클라이언트를 만드는 방법
struct YouTubeSetupGuide: View {
    var body: some View {
        List {
            Section {
                Text("PC OBS의 로그인 정보는 OBS 프로젝트 것이라 쓸 수 없어서, 자기 Google Cloud 프로젝트에 로그인용 클라이언트를 한 번 만들어 넣습니다. 비용은 들지 않습니다.")
            }
            Section("순서") {
                step(1, "console.cloud.google.com에서 새 프로젝트를 만듭니다.")
                step(2, "API 및 서비스 → 라이브러리에서 \"YouTube Data API v3\"를 찾아 사용 설정합니다.")
                step(3, "Google 인증 플랫폼(OAuth 동의 화면)을 시작합니다. 대상은 \"외부\", 앱 이름과 이메일을 넣습니다.")
                step(4, "대상 화면에서 \"앱 게시\"를 눌러 프로덕션으로 바꿉니다. 테스트 상태로 두면 로그인이 7일마다 풀립니다. 심사는 받지 않아도 됩니다.")
                step(5, "클라이언트 → 클라이언트 만들기에서 유형 \"iOS\", 번들 ID \"io.github.videin.broadcast\"로 만듭니다.")
                step(6, "만들어진 클라이언트 ID(…apps.googleusercontent.com)를 복사해 앱 설정에 붙여 넣고 로그인합니다.")
            }
            Section("로그인할 때") {
                Text("\"Google에서 확인하지 않은 앱\" 경고가 나오면 \"고급\" → \"(앱 이름)(으)로 이동\"을 누릅니다. 내가 만든 클라이언트라서 나오는 경고입니다.")
                Text("YouTube 계정 관리 권한을 허용해야 방송을 만들고 스트림 키를 받을 수 있습니다.")
            }
        }
        .navigationTitle("YouTube 로그인 설정")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.headline.monospacedDigit()).foregroundStyle(Color.accentColor)
            Text(text)
        }
    }
}
