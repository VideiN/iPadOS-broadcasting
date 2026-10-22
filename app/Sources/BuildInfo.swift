import SwiftUI

/// 이 앱이 어느 CI 실행에서 나왔는지 (app/CMakeLists.txt가 Info.plist에 넣는다).
/// 실기기에서 시험할 때 최신 빌드를 깔았는지 알아보게 한다: LiveContainer 목록의 버전(0.1.<실행 번호>), 설정, 오버레이, 로그 첫머리
struct BuildInfo {
    static let current = BuildInfo()

    /// GitHub Actions 실행 번호 (Actions 목록의 "#번호"). 로컬 빌드는 0
    let run: Int
    let runID: String
    let branch: String
    let commit: String
    let repository: String
    let time: Date?

    private init() {
        let info = Bundle.main.object(forInfoDictionaryKey: "BroadcastBuild") as? [String: Any] ?? [:]
        func value(_ key: String) -> String { info[key] as? String ?? "" }
        run = Int(value("Run")) ?? 0
        runID = value("RunID")
        branch = value("Branch")
        commit = value("Commit")
        repository = value("Repository")
        time = ISO8601DateFormatter().date(from: value("Time"))
    }

    var isCI: Bool { run > 0 }
    var shortCommit: String { String(commit.prefix(7)) }
    /// "#75 chat-source"
    var label: String { isCI ? "#\(run) \(branch)" : "로컬 빌드" }
    var runURL: URL? { isCI ? URL(string: "https://github.com/\(repository)/actions/runs/\(runID)") : nil }

    var logLine: String {
        guard isCI else { return "local" }
        let built = time.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        return "#\(run) \(branch) \(shortCommit) (run \(runID), built \(built))"
    }
}

/// 같은 브랜치에 이 빌드보다 새로 성공한 CI 빌드가 있는지 GitHub에 묻는다.
/// 공개 저장소라 로그인 없이 된다 (IP당 시간에 60번 한도). 앱을 켤 때 한 번, 설정에서 누를 때 다시
@MainActor
final class BuildCheck: ObservableObject {
    static let shared = BuildCheck()

    enum State: Equatable {
        case idle
        case checking
        case latest
        case newer(run: Int, title: String, url: URL?)
        case failed(String)
    }

    @Published private(set) var state = State.idle

    func check() async {
        let build = BuildInfo.current
        guard build.isCI, state != .checking,
            var components = URLComponents(
                string: "https://api.github.com/repos/\(build.repository)/actions/workflows/ios.yml/runs")
        else { return }
        components.queryItems = [
            URLQueryItem(name: "branch", value: build.branch),
            URLQueryItem(name: "status", value: "success"),
            URLQueryItem(name: "per_page", value: "1"),
        ]
        guard let url = components.url else { return }
        state = .checking

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw BuildCheckError(message: "GitHub 응답 \(status)") }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let newest = (json?["workflow_runs"] as? [[String: Any]])?.first
            if let newest, let number = newest["run_number"] as? Int, number > build.run {
                state = .newer(
                    run: number, title: newest["display_title"] as? String ?? "",
                    url: (newest["html_url"] as? String).flatMap { URL(string: $0) })
                appLog("build check: newer build #\(number) on \(build.branch)")
            } else {
                state = .latest
                appLog("build check: this is the latest build on \(build.branch)")
            }
        } catch {
            state = .failed(error.localizedDescription)
            appLog("build check: failed (\(error.localizedDescription))")
        }
    }
}

private struct BuildCheckError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 오버레이 첫 줄: "빌드  #75 chat-source", 새 빌드가 있으면 그 번호도
struct BuildOverlayLine: View {
    @ObservedObject private var check = BuildCheck.shared

    var body: some View {
        if case .newer(let run, _, _) = check.state {
            Text("빌드  \(BuildInfo.current.label) → 새 빌드 #\(run)").foregroundStyle(.orange)
        } else {
            Text("빌드  \(BuildInfo.current.label)")
        }
    }
}

/// 설정 › 정보의 빌드 줄들
struct BuildInfoRows: View {
    @ObservedObject private var check = BuildCheck.shared
    private let build = BuildInfo.current

    var body: some View {
        LabeledContent("빌드", value: build.label)
        if build.isCI {
            LabeledContent("커밋", value: build.shortCommit)
            if let time = build.time {
                LabeledContent("만든 시각", value: time.formatted(date: .numeric, time: .shortened))
            }
            Button {
                Task { await check.check() }
            } label: {
                status
            }
            .disabled(check.state == .checking)
            if case .newer(_, let title, let url) = check.state {
                if !title.isEmpty {
                    Text(title).font(.footnote).foregroundStyle(.secondary)
                }
                if let url {
                    Link("GitHub에서 새 빌드 열기", destination: url)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch check.state {
        case .idle:
            Label("최신 빌드인지 확인", systemImage: "arrow.clockwise")
        case .checking:
            HStack {
                Text("최신 빌드 확인 중…")
                Spacer()
                ProgressView()
            }
        case .latest:
            Label("이 브랜치의 최신 빌드입니다", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .newer(let run, _, _):
            Label("새 빌드가 있습니다: #\(run)", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        case .failed(let message):
            Label("확인하지 못했습니다 (\(message)). 다시 확인", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}
