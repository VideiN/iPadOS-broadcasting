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

/// 카메라·오디오 입력 장치. available이 false면 고른 장치가 빠져 있는 것(마지막으로 알던 이름)
struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let available: Bool
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
            core_start_capture()

            DispatchQueue.main.async {
                self.refreshDevices()
                self.observeDeviceChanges()
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
