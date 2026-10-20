import AVFoundation
import SwiftUI

/// 진단용 로그. 프로세스 시작 후 경과 시간을 앞에 붙인다.
/// libobs 로그와 함께 표준 출력과 Documents/broadcast.log에 남는다 (기기에서는 파일 앱으로 연다).
func appLog(_ message: String) {
    let uptime = ProcessInfo.processInfo.systemUptime - processStartUptime
    core_log(String(format: "[app %7.2fs] ", uptime) + message)
}

private let processStartUptime = ProcessInfo.processInfo.systemUptime

@main
struct BroadcastApp: App {
    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        core_log_open(documents.appendingPathComponent("broadcast.log").path)

        appLog("init")
        appLog("build: \(BuildInfo.current.logLine)")
        Core.shared.start()

        // 같은 브랜치에 더 새 빌드가 있는지 (오버레이·설정에 보인다). 시작 작업이 끝난 뒤에
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            await BuildCheck.shared.check()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// 카메라·오디오 입력 장치. available이 false면 고른 장치가 빠져 있는 것(마지막으로 알던 이름)
struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let available: Bool
}

/// libobs 시작과 상태
final class Core: ObservableObject {
    static let shared = Core()

    /// 캔버스 (기본 1080p60, 설정 화면에서 바꿈).
    /// CI 시뮬레이터는 소프트웨어 인코더라 1080p60을 따라가지 못해 `-canvas 640x360@30`으로 줄여 띄운다.
    @Published private(set) var width: UInt32
    @Published private(set) var height: UInt32
    @Published private(set) var fps: UInt32

    private init() {
        AppSettings.register()
        let defaults = AppSettings.defaults
        (width, height, fps) =
            Self.canvasFromArguments()
            ?? (
                UInt32(defaults.integer(forKey: AppSettings.canvasWidth)),
                UInt32(defaults.integer(forKey: AppSettings.canvasHeight)),
                UInt32(defaults.integer(forKey: AppSettings.canvasFPS))
            )
    }

    /// 캔버스를 바꾸고 저장한다. 녹화·송출 중이면 바꾸지 않는다.
    func applyCanvas(width: UInt32, height: UInt32, fps: UInt32) -> Bool {
        guard core_reset_canvas(width, height, fps) else { return false }
        self.width = width
        self.height = height
        self.fps = fps

        let defaults = AppSettings.defaults
        defaults.set(Int(width), forKey: AppSettings.canvasWidth)
        defaults.set(Int(height), forKey: AppSettings.canvasHeight)
        defaults.set(Int(fps), forKey: AppSettings.canvasFPS)
        appLog("canvas set to \(width)x\(height) @ \(fps)")
        return true
    }

    private static func canvasFromArguments() -> (UInt32, UInt32, UInt32)? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-canvas"), index + 1 < args.count else { return nil }

        let parts = args[index + 1].split(whereSeparator: { $0 == "x" || $0 == "@" }).compactMap { UInt32($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 > 0 }) else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    @Published private(set) var isRunning = false
    @Published private(set) var failed = false
    @Published private(set) var cameras: [Device] = []
    @Published private(set) var audioInputs: [Device] = []
    @Published private(set) var currentCamera = ""
    @Published private(set) var currentAudioInput = ""
    private var started = false
    private var observers: [NSObjectProtocol] = []

    /// libobs 초기화(Metal 셰이더 컴파일 포함)는 오래 걸릴 수 있어 메인 스레드 밖에서 한다.
    /// 메인 스레드에서 하면 그동안 런치 스크린에 멈춰 있고, 길어지면 iOS 워치독이 앱을 죽인다.
    /// 카메라·마이크 권한 요청은 초기화와 동시에 하고, 둘 다 끝나면 입력 소스를 만든다.
    func start() {
        guard !started, let resourcePath = Bundle.main.resourcePath else { return }
        started = true

        let ready = DispatchGroup()

        ready.enter()
        Self.requestPermissions { ready.leave() }

        let (width, height, fps) = (width, height, fps)
        var ok = false
        ready.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            ok = core_startup(resourcePath, width, height, fps)

            DispatchQueue.main.async {
                appLog(ok ? "core started" : "core_startup failed")
                self.isRunning = ok
                self.failed = !ok
            }
            ready.leave()
        }

        ready.notify(queue: .global(qos: .userInitiated)) {
            guard ok else { return }
            core_start_capture(Self.collectionPath())

            DispatchQueue.main.async {
                self.refreshDevices()
                self.observeDeviceChanges()
                SceneModel.shared.refresh()
                SceneModel.shared.runAutotestIfRequested()
                Outputs.shared.runAutotestIfRequested()
                Outputs.shared.runSRTAutotestIfRequested()
            }
        }
    }

    /// 장치를 바꾼다. 카메라 전환은 캡처 세션을 멈췄다 다시 열어 시간이 걸리므로 메인 스레드 밖에서 한다.
    func select(_ kind: core_device_kind, _ id: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            core_select_device(kind, id)
            DispatchQueue.main.async { self.refreshDevices() }
        }
    }

    func refreshDevices() {
        cameras = Self.devices(CORE_DEVICE_CAMERA)
        audioInputs = Self.devices(CORE_DEVICE_AUDIO_INPUT)
        currentCamera = Self.current(CORE_DEVICE_CAMERA)
        currentAudioInput = Self.current(CORE_DEVICE_AUDIO_INPUT)
    }

    /// 외부 카메라·USB 오디오 장치를 꽂거나 뺄 때 목록을 다시 읽는다
    private func observeDeviceChanges() {
        let names: [Notification.Name] = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
            AVAudioSession.routeChangeNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDevices()
            }
        }
    }

    /// 씬 구성 파일. 파일 앱에 보이지 않게 Application Support에 둔다
    private static func collectionPath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("scenes.json").path
    }

    private static func requestPermissions(_ done: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { camera in
            AVAudioApplication.requestRecordPermission { microphone in
                appLog("permissions: camera=\(camera) microphone=\(microphone)")
                done()
            }
        }
    }

    private static func devices(_ kind: core_device_kind) -> [Device] {
        guard let list = core_list_devices(kind) else { return [] }
        defer { core_free(list) }

        return String(cString: list).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return Device(id: String(parts[0]), name: String(parts[1]), available: parts[2] != "0")
        }
    }

    private static func current(_ kind: core_device_kind) -> String {
        guard let id = core_current_device(kind) else { return "" }
        defer { core_free(id) }
        return String(cString: id)
    }
}
