import BackgroundTasks
import SwiftUI
import UIKit

/// 백그라운드 송출 (P13): 앱을 떠나도 송출·녹화·리플레이를 계속한다.
///
/// - iPadOS 26의 계속 처리 작업(`BGContinuedProcessingTask`)을 출력을 시작할 때(사용자가 누른 순간, 앞에서) 낸다.
///   GPU를 쓸 수 있는 기기(`supportedResources`에 `.gpu`, M3 이후 아이패드)면 뒤에서도 장면 합성·인코딩이 이어진다.
///   시스템이 Live Activity로 진행을 보이고, 사용자는 거기서 끝낼 수 있다
/// - 마이크는 `UIBackgroundModes audio`로 이어진다. 출력 없이 뒤로 가면 마이크를 놓아 앱이 평소처럼 잠든다
/// - 카메라는 뒤에서 못 쓰므로, 뒤에 있는 동안 프로그램 출력을 자리 비움 장면으로 바꾼다 (scenes.c `core_away_begin`)
///
/// 메인 스레드에서만 쓴다 (Outputs의 1초 갱신, 화면 상태 변화)
final class BackgroundLive: ObservableObject {
    static let shared = BackgroundLive()
    static let taskIdentifier = "io.github.videin.broadcast.live"
    /// 뒤에서 GPU로 그려도 되는지가 바뀜 (아바타가 디스플레이 링크 대신 타이머로 그린다)
    static let renderingChanged = Notification.Name("BackgroundLiveRenderingChanged")

    /// 설정 화면에 보일 상태
    @Published private(set) var availability = ""
    /// 돌아온 뒤 잠깐 상태 줄에 보일 말
    @Published private(set) var notice: String?

    private var registered = false
    private var submittedAt: Date?
    private var task: AnyObject?  // BGContinuedProcessingTask (iOS 26)
    private var taskHasGPU = false
    private var everActive = false
    private var seconds: Int64 = 0
    private var awaySince: Date?
    private var mutedForAway = false
    private var suspendedAudio = false
    /// 뒤에 있으면서 GPU 작업이 돌고 있음 (아바타 등이 계속 그려도 됨)
    private(set) var backgroundRendering = false

    private init() {
        availability = Self.describeAvailability()
    }

    private static var enabled: Bool { AppSettings.defaults.bool(forKey: AppSettings.backgroundLive) }

    static func describeAvailability() -> String {
        guard #available(iOS 26, *) else { return "iPadOS 26 이상에서만 됩니다." }
        if BGTaskScheduler.supportedResources.contains(.gpu) {
            return "이 기기는 뒤에서도 GPU를 쓸 수 있습니다 (장면·인코딩 계속)."
        }
        return "이 기기는 뒤에서 GPU를 쓸 수 없어 영상이 멈출 수 있습니다 (소리·연결은 계속)."
    }

    /// 앱 시작 때 한 번 (작업을 내기 전에 등록해야 한다)
    func register() {
        guard #available(iOS 26, *), !registered else { return }
        registered = true
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            self.launched(task)
        }
        appLog("background task: \(ok ? "registered" : "registration failed") (\(Self.describeAvailability()))")
    }

    /// 사용자가 녹화·송출·리플레이를 시작함 (앞에서, 누른 순간). 작업이 없으면 낸다
    func userStartedOutput(_ kind: String) {
        guard Self.enabled else { return }
        guard #available(iOS 26, *) else {
            appLog("background task: needs iPadOS 26")
            return
        }
        guard registered, task == nil, submittedAt == nil else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier, title: "방송 중", subtitle: "\(kind) 시작")
        request.strategy = .fail
        let gpu = BGTaskScheduler.supportedResources.contains(.gpu)
        if gpu { request.requiredResources = .gpu }
        do {
            try BGTaskScheduler.shared.submit(request)
            submittedAt = Date()
            everActive = false
            appLog("background task: submitted for \(kind) (gpu \(gpu ? "yes" : "no"))")
        } catch {
            appLog("background task: submit failed: \(error.localizedDescription)")
        }
    }

    @available(iOS 26, *)
    private func launched(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        self.task = task
        taskHasGPU = BGTaskScheduler.supportedResources.contains(.gpu)
        seconds = 0
        task.progress.totalUnitCount = 3600
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async { self?.expired() }
        }
        appLog("background task: running (gpu \(taskHasGPU ? "yes" : "no"))")
    }

    /// Outputs가 1초마다: 진행을 알리고, 출력이 모두 멈추면 작업을 끝낸다
    func outputsChanged(active: Bool, stats: core_output_stats, kbps: Double) {
        if active { everActive = true }
        guard #available(iOS 26, *) else { return }
        if let task = task as? BGContinuedProcessingTask {
            if active {
                // 끝이 없는 작업: 1초에 1씩, 90%가 넘으면 한 시간 더 (멈춘 작업으로 보이지 않게)
                seconds += 1
                task.progress.completedUnitCount = seconds
                if seconds * 10 >= task.progress.totalUnitCount * 9 { task.progress.totalUnitCount += 3600 }
                if seconds % 5 == 1 { task.updateTitle("방송 중", subtitle: Self.subtitle(stats, kbps: kbps)) }
            } else if everActive {
                finish(success: true, reason: "outputs stopped")
            }
        }
        // 낸 지 30초가 지나도 출력이 켜지지 않았으면(시작 실패) 기다리지 않는다
        if !active, !everActive, let submittedAt, Date().timeIntervalSince(submittedAt) > 30 {
            finish(success: false, reason: "no output started")
        }
    }

    private static func subtitle(_ stats: core_output_stats, kbps: Double) -> String {
        var parts: [String] = []
        if stats.streaming { parts.append("송출 \(clock(stats.streaming_seconds)) · \(String(format: "%.1f", kbps / 1000)) Mbps") }
        if stats.recording { parts.append("녹화 \(clock(stats.recording_seconds))") }
        if stats.replay_active { parts.append("리플레이") }
        return parts.joined(separator: " · ")
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func finish(success: Bool, reason: String) {
        if #available(iOS 26, *), let task = task as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
            appLog("background task: completed (\(reason))")
        }
        task = nil
        submittedAt = nil
        everActive = false
        setRendering(false)
    }

    /// 사용자가 Live Activity에서 끝냈거나 시스템이 끝냄. 뒤에 있으면 출력을 깔끔히 멈춘다(녹화 파일 마무리)
    private func expired() {
        appLog("background task: expired (\(awaySince != nil ? "in the background, stopping outputs" : "app is active, outputs continue"))")
        let background = awaySince != nil
        finish(success: false, reason: "expired")
        guard background else {
            notice = "백그라운드 송출이 꺼졌습니다. 앱을 떠나면 송출이 멈출 수 있습니다."
            return
        }
        Outputs.queue.async {
            core_recording_stop(false)
            core_streaming_stop(false)
            core_replay_stop()
        }
    }

    // MARK: 앱이 뒤로·앞으로

    /// 화면이 뒤로 감. 출력 중이면 자리 비움 장면, 아니면 마이크를 놓는다
    func enteredBackground(outputsActive: Bool) {
        guard outputsActive else {
            core_audio_input_set_suspended(true)
            suspendedAudio = true
            appLog("background: no outputs, microphone released")
            return
        }
        guard Self.enabled else {
            appLog("background: outputs active but background live is off")
            return
        }
        guard awaySince == nil else { return }
        awaySince = Date()
        let defaults = AppSettings.defaults
        let scene = defaults.string(forKey: AppSettings.backgroundScene) ?? ""
        if scene != "*" {
            let image = Self.awayImagePath()
            _ = core_away_begin(scene, image ?? "", "잠시 자리를 비웠습니다")
        }
        if defaults.bool(forKey: AppSettings.backgroundMute) {
            core_source_set_muted(core_audio_input_name(), true)
            mutedForAway = true
        }
        let mode = task == nil ? "none" : (taskHasGPU ? "gpu" : "cpu")
        appLog("background: away scene \(scene == "*" ? "off (current scene)" : "on") (task \(mode)\(mutedForAway ? ", muted" : ""))")
        setRendering(task != nil && taskHasGPU)
    }

    /// 화면이 다시 앞으로
    func becameActive() {
        if suspendedAudio {
            suspendedAudio = false
            core_audio_input_set_suspended(false)
            appLog("background: microphone resumed")
        }
        guard let since = awaySince else { return }
        awaySince = nil
        core_away_end()
        if mutedForAway {
            core_source_set_muted(core_audio_input_name(), false)
            mutedForAway = false
        }
        setRendering(false)
        let seconds = Int(Date().timeIntervalSince(since).rounded())
        appLog("background: back after \(seconds) s")
        notice = "\(seconds)초 동안 자리 비움 화면을 보냈습니다"
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.notice?.hasSuffix("보냈습니다") == true { self?.notice = nil }
        }
    }

    private func setRendering(_ on: Bool) {
        guard on != backgroundRendering else { return }
        backgroundRendering = on
        NotificationCenter.default.post(name: Self.renderingChanged, object: nil)
    }

    /// 자동 자리 비움 화면의 이미지 (Documents 기준 상대 경로로 저장, 없으면 nil)
    static func awayImagePath() -> String? {
        guard let relative = AppSettings.defaults.string(forKey: AppSettings.awayImage), !relative.isEmpty else {
            return nil
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    // MARK: CI

    /// `-autotest-background`: 출력 시험이 송출하는 동안 뒤로 간 것처럼 자리 비움을 6초 켠다 (시뮬레이터는 진짜로 뒤에
    /// 보내기 어렵다). 실제 앱 상태와 상관없이 같은 코드를 지난다
    func runAutotest(after delay: Double) {
        guard ProcessInfo.processInfo.arguments.contains("-autotest-background") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            appLog("background autotest: entering")
            self.enteredBackground(outputsActive: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                let active = core_away_active()
                self.becameActive()
                appLog("background autotest: \(active && !core_away_active() ? "ok" : "failed") (away was \(active))")
            }
        }
    }
}

/// 설정 › 송출의 "백그라운드" 섹션
struct BackgroundLiveSection: View {
    @ObservedObject private var live = BackgroundLive.shared
    @ObservedObject private var model = SceneModel.shared
    @AppStorage(AppSettings.backgroundLive) private var enabled = true
    @AppStorage(AppSettings.backgroundScene) private var scene = ""
    @AppStorage(AppSettings.backgroundMute) private var mute = false
    @AppStorage(AppSettings.awayImage) private var awayImage = ""

    var body: some View {
        Section {
            Toggle("앱을 떠나도 계속", isOn: $enabled)
            if enabled {
                Picker("떠나 있는 동안 보낼 화면", selection: $scene) {
                    Text("자리 비움 화면").tag("")
                    Text("지금 장면 그대로").tag("*")
                    ForEach(model.scenes, id: \.self) { Text($0).tag($0) }
                }
                if scene.isEmpty {
                    Picker("자리 비움 이미지", selection: $awayImage) {
                        Text("글자만 (잠시 자리를 비웠습니다)").tag("")
                        ForEach(Self.mediaImages(), id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                    }
                }
                Toggle("떠나 있는 동안 소리 끄기", isOn: $mute)
            }
        } header: {
            Text("백그라운드")
        } footer: {
            Text(
                "\(live.availability) 카메라는 앱을 떠나면 쓸 수 없어 자리 비움 화면으로 바뀌고, 돌아오면 원래 장면으로 돌아옵니다. 떠나 있는 동안 화면 위쪽(Live Activity)에 방송 중으로 보이며 거기서 끝낼 수 있습니다. 앱 전환기에서 앱을 닫으면 멈춥니다."
            )
        }
    }

    /// Documents/Media의 이미지 (사진 가져오기·파일로 넣은 것)
    private static func mediaImages() -> [String] {
        let media = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Media")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []
        return names.filter { ["png", "jpg", "jpeg", "heic", "webp"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted().map { "Media/" + $0 }
    }
}
