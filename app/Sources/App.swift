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
final class Core {
    static let shared = Core()

    /// 캔버스 설정 (계획: 1080p60 단일 캔버스)
    let width: UInt32 = 1920
    let height: UInt32 = 1080
    let fps: UInt32 = 60

    private(set) var isRunning = false

    func start() {
        guard !isRunning, let resourcePath = Bundle.main.resourcePath else { return }

        isRunning = core_startup(resourcePath, width, height, fps)
        appLog(isRunning ? "core started" : "core_startup failed")
    }
}
