import SwiftUI

/// 진단용 로그. 프로세스 시작 후 경과 시간을 앞에 붙인다.
func appLog(_ message: String) {
    let uptime = ProcessInfo.processInfo.systemUptime - processStartUptime
    print(String(format: "[app %7.2fs] ", uptime) + message)
}

private let processStartUptime = ProcessInfo.processInfo.systemUptime

@main
struct BroadcastApp: App {
    init() {
        appLog("init")
        Core.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// libobs 시작과 상태
final class Core: ObservableObject {
    static let shared = Core()

    /// 캔버스 설정 (계획: 1080p60 단일 캔버스)
    let width: UInt32 = 1920
    let height: UInt32 = 1080
    let fps: UInt32 = 60

    @Published private(set) var isRunning = false
    @Published private(set) var failed = false
    private var started = false

    /// libobs 초기화(Metal 셰이더 컴파일 포함)는 오래 걸릴 수 있어 메인 스레드 밖에서 한다.
    /// 메인 스레드에서 하면 그동안 런치 스크린에 멈춰 있고, 길어지면 iOS 워치독이 앱을 죽인다.
    func start() {
        guard !started, let resourcePath = Bundle.main.resourcePath else { return }
        started = true

        let (width, height, fps) = (width, height, fps)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = core_startup(resourcePath, width, height, fps)

            DispatchQueue.main.async {
                appLog(ok ? "core started" : "core_startup failed")
                self.isRunning = ok
                self.failed = !ok
            }
        }
    }
}
