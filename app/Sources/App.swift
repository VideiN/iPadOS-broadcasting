import SwiftUI

@main
struct BroadcastApp: App {
    init() {
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
        print(isRunning ? "[app] core started" : "[app] core_startup failed")
    }
}
