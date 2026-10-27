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
    /// 메뉴 막대가 보는 값 (바뀔 때만 알린다)
    @StateObject private var menuState = MenuState(outputs: .shared, model: .shared)

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        core_log_open(documents.appendingPathComponent("broadcast.log").path)

        appLog("init")
        appLog("build: \(BuildInfo.current.logLine)")
        // CI 채팅 시험은 직접 받기부터 보므로 채팅 패널을 숨긴 채 띄운다 (시험이 차례로 보였다 숨긴다)
        if ProcessInfo.processInfo.arguments.contains("-autotest-chat") {
            UserDefaults.standard.set(false, forKey: AppSettings.chatPanelShown)
        }
        // 아바타 소스 (P9, iOS 18+): libobs가 뜰 때 등록되도록 먼저
        AvatarSources.install()
        // 백그라운드 송출 (P13): 계속 처리 작업은 내기 전에 등록해야 한다
        BackgroundLive.shared.register()
        Core.shared.start()

        // 아이폰 얼굴 추적 받기 (P9). CI(`-autotest-facelink <페어링 코드>`)는 그 코드로 켜고 합성 송신기를 받는다
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-autotest-facelink"), index + 1 < args.count {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: AppSettings.faceLinkEnabled)
            defaults.set(args[index + 1], forKey: AppSettings.faceLinkToken)
            defaults.set(false, forKey: AppSettings.faceLinkAcceptVMC)
            defaults.set(39539, forKey: AppSettings.faceLinkPort)
            defaults.removeObject(forKey: AppSettings.faceLinkAllowed)
            Task { @MainActor in await FaceLinkReceiver.shared.runAutotest() }
        }
        FaceLinkReceiver.shared.applySettings()

        // 같은 브랜치에 더 새 빌드가 있는지 (오버레이·설정에 보인다). 시작 작업이 끝난 뒤에
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            await BuildCheck.shared.check()
        }
    }

    var body: some Scene {
        WindowGroup {
            // 상태 표시줄은 설정에 따라 ContentView가 보이거나 숨긴다
            ContentView()
                .persistentSystemOverlays(.hidden)
        }
        .commands { StudioCommands(outputs: .shared, model: .shared, menu: menuState) }
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
    /// fps는 분수(29.97 = 30000/1001)
    @Published private(set) var width: UInt32
    @Published private(set) var height: UInt32
    @Published private(set) var frameRate: FrameRateChoice

    var fps: Double { frameRate.fps }
    /// 캔버스 색 (P11). `-canvas-color 601,full`로 띄우면 그 값 (저장하지 않음)
    @Published private(set) var color: CanvasColor
    /// 이 실행이 시작할 때 쓴 오디오 형식 (설정을 바꾸면 다시 열어야 적용된다)
    private(set) var audioFormat = (sampleRate: 48000, channels: 2)
    /// 이 실행의 오디오 버퍼링 (P13)
    private(set) var audioFixedBuffering = true

    private init() {
        AppSettings.register()
        let defaults = AppSettings.defaults
        color =
            Self.colorFromArguments()
            ?? CanvasColor(
                colorSpace: defaults.integer(forKey: AppSettings.canvasColorSpace),
                range: defaults.integer(forKey: AppSettings.canvasRange))
        if let canvas = Self.canvasFromArguments() {
            (width, height, frameRate) = canvas
        } else {
            width = UInt32(defaults.integer(forKey: AppSettings.canvasWidth))
            height = UInt32(defaults.integer(forKey: AppSettings.canvasHeight))
            // 분수로 저장하기 전(정수 canvasFPS만 있던 때)의 값도 읽는다
            let numerator = defaults.integer(forKey: AppSettings.canvasFPSNum)
            let denominator = defaults.integer(forKey: AppSettings.canvasFPSDen)
            frameRate =
                numerator > 0 && denominator > 0
                ? FrameRateChoice(numerator: numerator, denominator: denominator)
                : FrameRateChoice(numerator: max(defaults.integer(forKey: AppSettings.canvasFPS), 1), denominator: 1)
        }
    }

    /// 캔버스를 바꾸고 저장한다. 녹화·송출 중이면 바꾸지 않는다.
    func applyCanvas(width: UInt32, height: UInt32, frameRate: FrameRateChoice, color: CanvasColor? = nil) -> Bool {
        let color = color ?? self.color
        guard frameRate.numerator > 0, frameRate.denominator > 0 else { return false }
        core_set_canvas_color(Int32(color.colorSpace), Int32(color.range))
        guard core_reset_canvas(width, height, UInt32(frameRate.numerator), UInt32(frameRate.denominator)) else {
            core_set_canvas_color(Int32(self.color.colorSpace), Int32(self.color.range))
            return false
        }
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.color = color

        let defaults = AppSettings.defaults
        defaults.set(Int(width), forKey: AppSettings.canvasWidth)
        defaults.set(Int(height), forKey: AppSettings.canvasHeight)
        defaults.set(frameRate.numerator, forKey: AppSettings.canvasFPSNum)
        defaults.set(frameRate.denominator, forKey: AppSettings.canvasFPSDen)
        defaults.set(Int(frameRate.fps.rounded()), forKey: AppSettings.canvasFPS)
        defaults.set(color.colorSpace, forKey: AppSettings.canvasColorSpace)
        defaults.set(color.range, forKey: AppSettings.canvasRange)
        appLog("canvas set to \(width)x\(height) @ \(frameRate.logText), \(color.logText)")
        return true
    }

    /// `-canvas-color 601,full`
    private static func colorFromArguments() -> CanvasColor? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-canvas-color"), index + 1 < args.count else { return nil }
        let parts = args[index + 1].split(separator: ",").map(String.init)
        guard parts.count == 2, let space = CanvasColor.spaces.first(where: { $0.name == parts[0] }) else { return nil }
        return CanvasColor(colorSpace: space.value, range: parts[1] == "full" ? 2 : 1)
    }

    /// 오디오 출력 형식 (P11): 설정값, 또는 `-audio 44100,mono`. 시작할 때만 정해진다
    private static func startupAudioFormat() -> (sampleRate: UInt32, channels: Int32) {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-audio"), index + 1 < args.count {
            let parts = args[index + 1].split(separator: ",")
            if parts.count == 2, let rate = UInt32(parts[0]) {
                return (rate, parts[1] == "mono" ? 1 : 2)
            }
        }
        let defaults = AppSettings.defaults
        return (UInt32(defaults.integer(forKey: AppSettings.audioSampleRate)),
                Int32(defaults.integer(forKey: AppSettings.audioChannels)))
    }

    /// `-canvas 640x360@30`, `@30000/1001`, `@29.97`
    private static func canvasFromArguments() -> (UInt32, UInt32, FrameRateChoice)? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-canvas"), index + 1 < args.count else { return nil }

        let value = args[index + 1].split(separator: "@", maxSplits: 1)
        guard value.count == 2, let frameRate = FrameRateChoice(text: String(value[1])) else { return nil }
        let size = value[0].split(separator: "x").compactMap { UInt32($0) }
        guard size.count == 2, size.allSatisfy({ $0 > 0 }) else { return nil }
        return (size[0], size[1], frameRate)
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

        let (width, height) = (width, height)
        let (fpsNum, fpsDen) = (UInt32(frameRate.numerator), UInt32(frameRate.denominator))
        core_set_canvas_color(Int32(color.colorSpace), Int32(color.range))
        let audio = Self.startupAudioFormat()
        core_set_audio_format(audio.sampleRate, audio.channels)
        audioFormat = (Int(audio.sampleRate), Int(audio.channels))
        audioFixedBuffering = AppSettings.defaults.bool(forKey: AppSettings.audioFixedBuffering)
        core_set_audio_buffering(audioFixedBuffering, 128)
        var ok = false
        ready.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            ok = core_startup(resourcePath, width, height, fpsNum, fpsDen)

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
                // 유튜브 채팅 받기 (P7): 채팅 소스나 패널이 있고 로그인돼 있으면 받는다
                MainActor.assumeIsolated {
                    ChatFeed.shared.tick()
                    UIAutotest.runIfRequested()
                }
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
