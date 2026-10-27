import Combine
import SwiftUI

/// 녹화·송출 상태 (P3). 실제 일은 Core/outputs.c가 한다.
final class Outputs: ObservableObject {
    static let shared = Outputs()

    @Published private(set) var stats = core_output_stats()
    @Published private(set) var streamKbps: Double = 0
    @Published private(set) var recordError = ""
    @Published private(set) var streamError = ""
    /// 중지를 눌렀지만 아직 멈추지 않은 상태. 이때 한 번 더 누르면 강제로 멈춘다
    @Published private(set) var recordStopping = false
    @Published private(set) var streamStopping = false
    /// YouTube 계정 송출: 방송을 만들고 스트림 키를 받는 중 (P8)
    @Published private(set) var streamPreparing = false
    /// 방송 준비 실패 이유 (다음 송출 시도까지 보인다)
    @Published private(set) var streamPrepareError = ""

    /// 시작을 요청하고 결과를 기다리는 중 (P13). 이때 같은 단추를 또 누르면 무시한다
    @Published private(set) var recordStarting = false
    @Published private(set) var replayStarting = false
    @Published private(set) var streamStarting = false

    @Published private(set) var streamFPS: Double = 0
    @Published private(set) var recordFPS: Double = 0

    /// 방금 저장한 리플레이 파일 이름 (몇 초 동안 위쪽 막대에 보인다)
    @Published private(set) var replayNotice: String?
    private var lastReplaySavedCount: Int32 = 0

    private var timer: AnyCancellable?
    /// 출력 시작·중지·저장은 모두 이 한 줄로 (P13): 녹화와 리플레이가 같은 인코더를 동시에 만들거나 놓지 않게
    static let queue = DispatchQueue(label: "outputs", qos: .userInitiated)
    /// 멈춤·시작을 센 값 (늘면 방금 일어난 것): 오류로 멈추면 알리고, 송출이 시작되면 링크를 공유한다
    private var seenRecordStops: Int32 = 0
    private var seenStreamStops: Int32 = 0
    private var seenStreamStarts: Int32 = 0
    /// 지금 송출이 어느 모드로 시작했는지 (방송 링크용)
    private(set) var streamTarget: BroadcastLink.Target?
    private var lastStreamBytes: UInt64 = 0
    private var lastStreamFrames: Int32 = 0
    private var lastRecordFrames: Int32 = 0
    private var lastUpdate = Date()

    private init() {
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.update() }
    }

    func update() {
        guard Core.shared.isRunning else { return }

        var stats = core_output_stats()
        core_get_output_stats(&stats)

        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdate)
        if stats.streaming, elapsed > 0, stats.stream_bytes >= lastStreamBytes {
            streamKbps = Double(stats.stream_bytes - lastStreamBytes) * 8 / 1000 / elapsed
        } else if !stats.streaming {
            streamKbps = 0
        }

        // 실제로 내보낸 비디오 프레임의 초당 개수 (캔버스 fps와 같아야 한다)
        if stats.streaming, elapsed > 0, stats.stream_total_frames >= lastStreamFrames {
            streamFPS = Double(stats.stream_total_frames - lastStreamFrames) / elapsed
        } else if !stats.streaming {
            streamFPS = 0
        }
        if stats.recording, elapsed > 0, stats.record_total_frames >= lastRecordFrames {
            recordFPS = Double(stats.record_total_frames - lastRecordFrames) / elapsed
        } else if !stats.recording {
            recordFPS = 0
        }

        lastStreamBytes = stats.stream_bytes
        lastStreamFrames = stats.stream_total_frames
        lastRecordFrames = stats.record_total_frames
        lastUpdate = now

        if stats.replay_saved_count > lastReplaySavedCount {
            lastReplaySavedCount = stats.replay_saved_count
            if let pointer = core_replay_last_path() {
                let name = URL(fileURLWithPath: String(cString: pointer)).lastPathComponent
                core_free(pointer)
                replayNotice = name
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    if self?.replayNotice == name { self?.replayNotice = nil }
                }
            }
        }

        self.stats = stats
        recordError = Self.lastError(stream: false)
        streamError = Self.lastError(stream: true)
        if !stats.recording { recordStopping = false }
        // 녹화가 끝나면 고른 폴더의 접근을 놓는다
        if !stats.recording && !recordStarting && recordingFolder != nil { releaseRecordingFolder() }
        if !stats.streaming { streamStopping = false }
        noticeEvents(stats)
        BackgroundLive.shared.outputsChanged(
            active: stats.recording || stats.streaming || stats.replay_active || stats.stream_reconnecting,
            stats: stats, kbps: streamKbps)
    }

    /// 오류로 멈춘 출력을 알리고(시트 위에서도 보이는 창), 송출이 새로 시작되면 방송 링크를 공유한다
    private func noticeEvents(_ stats: core_output_stats) {
        if stats.record_stop_count != seenRecordStops {
            seenRecordStops = stats.record_stop_count
            if stats.record_stop_code != 0 {
                OutputAlert.show(title: "녹화가 멈췄습니다", message: recordError, log: "recording stopped: \(recordError)")
            }
        }
        if stats.stream_stop_count != seenStreamStops {
            seenStreamStops = stats.stream_stop_count
            if stats.stream_stop_code != 0 {
                OutputAlert.show(title: "송출이 멈췄습니다", message: streamError, log: "streaming stopped: \(streamError)")
            }
        }
        if stats.stream_start_count != seenStreamStarts {
            seenStreamStarts = stats.stream_start_count
            BroadcastLink.streamStarted(streamTarget)
        }
    }

    /// 시작·중지는 인코더 세션을 만들고 닫느라 시간이 걸릴 수 있어 메인 스레드 밖에서 한다
    func toggleRecording() {
        guard !recordStarting else {
            appLog("recording: already starting, ignored")
            return
        }
        let active = stats.recording
        let force = recordStopping
        if active { recordStopping = true }

        let (video, audio) = Self.recordEncoding()
        let path = active ? "" : newRecordingPath()
        if !active {
            recordStarting = true
            BackgroundLive.shared.userStartedOutput("녹화")
        }

        Self.queue.async {
            var started = false
            if active {
                core_recording_stop(force)
            } else {
                var video = video
                var audio = audio
                started = core_recording_start(path, &video, &audio)
                appLog("recording start \(started ? "requested" : "failed"): \(path)")
            }
            DispatchQueue.main.async {
                if !active {
                    self.recordStarting = false
                    if !started { self.releaseRecordingFolder() }
                }
                self.update()
            }
        }
    }

    /// 리플레이 버퍼 켜기·끄기. 저장 위치는 앱의 Recordings 폴더 (고른 외장 폴더는 녹화에만 쓴다)
    func toggleReplay() {
        guard !replayStarting else {
            appLog("replay buffer: already starting, ignored")
            return
        }
        let active = stats.replay_active
        let defaults = AppSettings.defaults
        let seconds = Int32(defaults.integer(forKey: AppSettings.replaySeconds))
        let maxMB = Int32(defaults.integer(forKey: AppSettings.replayMaxMB))
        let (video, audio) = Self.recordEncoding()
        let directory = RecordingFolder.defaultFolder.path
        if !active {
            replayStarting = true
            BackgroundLive.shared.userStartedOutput("리플레이")
        }

        Self.queue.async {
            if active {
                core_replay_stop()
            } else {
                var video = video
                var audio = audio
                let ok = core_replay_start(directory, seconds, maxMB, &video, &audio)
                appLog("replay buffer start \(ok ? "requested" : "failed")")
            }
            DispatchQueue.main.async {
                if !active { self.replayStarting = false }
                self.update()
            }
        }
    }

    /// 녹화와 리플레이가 같이 쓰는 인코딩 (설정 › 녹화)
    private static func recordEncoding() -> (core_video_encoding, core_audio_encoding) {
        let settings = EncoderSettings.load(.record)
        let core = Core.shared
        return (settings.video(canvasWidth: core.width, canvasHeight: core.height), settings.audio)
    }

    func saveReplay() {
        Self.queue.async { core_replay_save() }
    }

    /// 송출 서버를 아직 정하지 않았거나 YouTube에 로그인하지 않았으면 false (설정을 열어야 함)
    @discardableResult
    func toggleStreaming() -> Bool {
        guard !streamPreparing, !streamStarting else {
            appLog("streaming: already starting, ignored")
            return true
        }
        let active = stats.streaming
        let defaults = AppSettings.defaults
        let mode = defaults.string(forKey: AppSettings.streamMode)
        let youtube = mode == "youtube"
        let chzzk = mode == "chzzk"
        let server = chzzk ? Chzzk.server : defaults.string(forKey: AppSettings.streamServer) ?? ""

        if !active && youtube {
            // YouTube 계정: 방송을 만들고 받은 주소·키로 보낸다
            guard YouTubeAccount.shared.loggedIn else { return false }
            streamPreparing = true
            streamPrepareError = ""
            BackgroundLive.shared.userStartedOutput("송출")
            Task {
                do {
                    let target = try await YouTubeAccount.shared.prepareStream()
                    await MainActor.run {
                        self.startStreaming(
                            server: target.server, key: target.key,
                            encoding: .stream(chzzk: false, canvasHeight: Core.shared.height),
                            target: .youtube(broadcastID: target.broadcastID))
                    }
                } catch {
                    appLog("youtube: stream preparation failed: \(error.localizedDescription)")
                    await MainActor.run {
                        self.streamPreparing = false
                        self.streamPrepareError = error.localizedDescription
                    }
                }
            }
            return true
        }

        guard active || !server.isEmpty else { return false }
        if active {
            let force = streamStopping
            streamStopping = true
            if youtube { YouTubeAccount.shared.endBroadcast() }
            Self.queue.async {
                core_streaming_stop(force)
                DispatchQueue.main.async { self.update() }
            }
        } else {
            // 치지직은 스트림 키가 있어야 한다 (없으면 설정을 연다)
            let key = chzzk ? Chzzk.keyStore.load() : StreamKeyStore.load()
            guard !chzzk || !key.isEmpty else { return false }
            streamPrepareError = ""
            BackgroundLive.shared.userStartedOutput("송출")
            startStreaming(
                server: server, key: key, encoding: .stream(chzzk: chzzk, canvasHeight: Core.shared.height),
                target: chzzk ? .chzzk : .manual)
        }
        return true
    }

    private func startStreaming(server: String, key: String, encoding: EncoderSettings, target: BroadcastLink.Target) {
        let video = Self.streamVideo(encoding)
        let options = StreamOptions.current()
        streamStarting = true
        streamTarget = target
        Self.queue.async {
            let ok = Self.start(server: server, key: key, video: video, audio: encoding.audio, options: options)
            appLog("streaming start \(ok ? "requested" : "failed")")
            DispatchQueue.main.async {
                self.streamPreparing = false
                self.streamStarting = false
                if !ok {
                    OutputAlert.show(
                        title: "송출을 시작하지 못했습니다", message: Self.lastError(stream: true),
                        log: "streaming failed to start")
                }
                self.update()
            }
        }
    }

    /// 캔버스 크기를 읽으므로 메인 스레드에서 부른다
    private static func streamVideo(_ encoding: EncoderSettings) -> core_video_encoding {
        encoding.video(canvasWidth: Core.shared.width, canvasHeight: Core.shared.height)
    }

    private static func start(
        server: String, key: String, video: core_video_encoding, audio: core_audio_encoding, options: core_stream_options
    ) -> Bool {
        var video = video
        var audio = audio
        var options = options
        return core_streaming_start(server, key, &video, &audio, &options)
    }

    /// CI용: `-autotest-output <초> <RTMP 서버 URL>`로 띄우면 입력 소스가 준비된 뒤
    /// 녹화(Documents/Recordings/autotest.mp4)와 송출(스트림 키 "autotest")을 함께 돌리고 멈춘다.
    func runAutotestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-autotest-output"), index + 2 < args.count,
            let seconds = Double(args[index + 1])
        else { return }
        let server = args[index + 2]
        let path = RecordingFolder.defaultFolder.appendingPathComponent("autotest.mp4").path

        // -autotest-youtube <mock 주소>: 송출 주소·키를 YouTube 로그인·방송 만들기 흐름으로 받는다 (P8)
        if let youtubeIndex = args.firstIndex(of: "-autotest-youtube"), youtubeIndex + 1 < args.count {
            let base = args[youtubeIndex + 1]
            Task {
                do {
                    let target = try await YouTubeAccount.shared.runAutotest(base: base)
                    appLog("youtube autotest: ok (broadcast \(target.broadcastID ?? "none"))")
                    // 송출이 시작되면 이 방송의 링크로 공유 창을 띄운다 (P13, -autotest-share가 닫는다)
                    await MainActor.run { self.streamTarget = .youtube(broadcastID: target.broadcastID) }
                    self.runOutputAutotest(seconds: seconds, path: path, server: target.server, key: target.key)
                    // -autotest-chat <mock 주소>: 이 방송의 채팅을 직접·패널·API로 받아 본다 (P7)
                    Task { @MainActor in await ChatFeed.shared.runAutotest() }
                } catch {
                    appLog("youtube autotest: failed (\(error.localizedDescription))")
                    self.runOutputAutotest(seconds: seconds, path: path, server: server, key: "autotest")
                }
            }
        } else {
            runOutputAutotest(seconds: seconds, path: path, server: server, key: "autotest")
        }
    }

    private func runOutputAutotest(seconds: Double, path: String, server: String, key: String) {
        appLog("autotest: recording and streaming for \(seconds) s to \(server)")
        // -autotest-chzzk: 송출을 치지직 권장값(키프레임 1초, B프레임 없음)으로. CI가 받은 영상의 키프레임 간격을 본다
        var encoding = EncoderSettings(codec: "h264", rateControl: "CBR", videoKbps: 4000, audioKbps: 160)
        if ProcessInfo.processInfo.arguments.contains("-autotest-chzzk") {
            encoding = encoding.forChzzk(keyint: 1, canvasHeight: Core.shared.height)
            appLog("autotest: streaming with the chzzk encoding")
        }
        let streamVideo = Self.streamVideo(encoding)
        // 혼잡 시 비트레이트 조절을 켠 RTMP (P11): CI가 rtmp-stream의 "Dynamic bitrate" 줄을 본다
        let options = core_stream_options(dyn_bitrate: true, reconnect: true, retries: 20, retry_sec: 5, delay_sec: 0)
        let record = EncoderSettings(codec: "hevc", rateControl: "ABR", videoKbps: 20000, audioKbps: 192)
        let recordVideo = Self.streamVideo(record)
        let queue = DispatchQueue.global(qos: .userInitiated)
        DispatchQueue.main.async { BackgroundLive.shared.userStartedOutput("CI") }
        queue.asyncAfter(deadline: .now() + 3) {
            // 녹화와 리플레이 버퍼(7초, 목록에 없는 직접 입력 값)를 두 스레드에서 같은 순간 시작한다 (P13):
            // 같은 녹화 인코더를 같이 쓰므로 인코더는 한 번만 만들어져야 한다 (CI가 "Record Video:" 줄을 센다)
            var started = [false, false]
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                var video = recordVideo
                var audio = record.audio
                let ok =
                    index == 0
                    ? core_recording_start(path, &video, &audio)
                    : core_replay_start(RecordingFolder.defaultFolder.path, 7, 2048, &video, &audio)
                lock.withLock { started[index] = ok }
            }
            let (recording, replay) = (started[0], started[1])
            let streaming = Self.start(
                server: server, key: key, video: streamVideo, audio: encoding.audio, options: options)
            appLog("autotest: started (recording \(recording), streaming \(streaming), replay \(replay))")
            // -autotest-background: 송출하는 동안 6초 자리 비움 (P13)
            DispatchQueue.main.async { BackgroundLive.shared.runAutotest(after: 5) }

            queue.asyncAfter(deadline: .now() + seconds) {
                core_replay_save()
                var stats = core_output_stats()
                core_get_output_stats(&stats)
                appLog(
                    String(
                        format:
                            "autotest: recording %.1f s %llu bytes, streaming %.1f s %llu bytes, dropped %d/%d, encoder skipped %u/%u",
                        stats.recording_seconds, stats.recording_bytes, stats.streaming_seconds, stats.stream_bytes,
                        stats.stream_dropped_frames, stats.stream_total_frames, stats.encoder_skipped_frames,
                        stats.video_total_frames))
                core_recording_stop(false)
                core_streaming_stop(false)

                // 멈춤은 비동기다 (남은 패킷 처리, MP4 정리, 연결 종료). 10초 안에 안 끝나면 강제로 멈춘다
                queue.asyncAfter(deadline: .now() + 10) {
                    var stats = core_output_stats()
                    core_get_output_stats(&stats)
                    appLog("autotest: replay saved \(stats.replay_saved_count)")
                    core_replay_stop()
                    if stats.recording || stats.streaming {
                        appLog("autotest: outputs still active after 10 s, forcing stop")
                        if stats.recording { core_recording_stop(true) }
                        if stats.streaming { core_streaming_stop(true) }
                    }

                    queue.asyncAfter(deadline: .now() + 2) {
                        appLog(
                            "autotest: done (record error '\(Self.lastError(stream: false))', stream error '\(Self.lastError(stream: true))')"
                        )
                        DispatchQueue.main.async { self.runStabilityAutotest() }
                    }
                }
            }
        }
    }

    /// CI (`-autotest-p13`, 출력 시험이 끝난 뒤): 시작 중 두 번 누르기를 무시하는지, 연결이 안 되는 서버로 송출하면
    /// 오류 알림이 뜨는지 (P13)
    private func runStabilityAutotest() {
        guard ProcessInfo.processInfo.arguments.contains("-autotest-p13") else { return }
        appLog("p13 autotest: start")
        // 리플레이 시작을 연달아 두 번: 두 번째는 무시돼야 한다. 켜지면 끈다
        toggleReplay()
        toggleReplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.stats.replay_active { self.toggleReplay() }
            // 아무도 듣지 않는 포트: 연결 실패로 멈추고 알림이 떠야 한다
            let encoding = EncoderSettings(codec: "h264", rateControl: "CBR", videoKbps: 1000, audioKbps: 128)
            self.startStreaming(server: "rtmp://127.0.0.1:9/live", key: "autotest", encoding: encoding, target: .manual)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                MainActor.assumeIsolated {
                    let shown = OutputAlert.dismissForTest()
                    appLog(
                        "p13 autotest: done (alert \(shown ? "shown" : "missing"), stream error '\(Self.lastError(stream: true))')")
                }
            }
        }
    }

    /// CI용: `-autotest-srt <초> <SRT URL>`로 띄우면 SRT 송출만 돌리고 멈춘다 (P5, obs-ffmpeg mpegts 출력)
    func runSRTAutotestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-autotest-srt"), index + 2 < args.count,
            let seconds = Double(args[index + 1])
        else { return }
        let server = args[index + 2]
        let encoding = EncoderSettings(codec: "h264", rateControl: "CBR", videoKbps: 3000, audioKbps: 160)
        let streamVideo = Self.streamVideo(encoding)
        let options = core_stream_options(dyn_bitrate: false, reconnect: true, retries: 20, retry_sec: 5, delay_sec: 0)

        // 같은 시간 동안 다른 인코딩 설정으로 녹화한다 (P11): ABR + 최대 비트레이트, 키프레임 1초, B프레임 없음,
        // H.264 main, 캔버스 높이의 절반으로 줄인 출력. CI가 ffprobe로 크기·키프레임·B프레임·색·오디오를 본다
        let record = EncoderSettings(
            codec: "h264", rateControl: "ABR", videoKbps: 2500, limitBitrate: true, maxBitrateKbps: 3000,
            maxBitrateWindow: 1.5, keyintSeconds: 1, profile: "main", bframes: false,
            outputHeight: Int(Core.shared.height) / 2, audioKbps: 128)
        let recordVideo = Self.streamVideo(record)
        let recordPath = RecordingFolder.defaultFolder.appendingPathComponent("encoding-test.mp4").path

        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.asyncAfter(deadline: .now() + 3) {
            let started = Self.start(
                server: server, key: "autotest", video: streamVideo, audio: encoding.audio, options: options)
            appLog("srt autotest: started \(started)")
            var video = recordVideo
            var audio = record.audio
            let recording = core_recording_start(recordPath, &video, &audio)
            appLog("encoding autotest: recording \(recording) (\(record.summary), output height \(record.outputHeight))")

            queue.asyncAfter(deadline: .now() + seconds) {
                var stats = core_output_stats()
                core_get_output_stats(&stats)
                appLog(
                    String(
                        format: "srt autotest: streamed %.1f s %llu bytes, dropped %d/%d", stats.streaming_seconds,
                        stats.stream_bytes, stats.stream_dropped_frames, stats.stream_total_frames))
                appLog(String(format: "encoding autotest: recorded %.1f s", stats.recording_seconds))
                core_streaming_stop(false)
                core_recording_stop(false)

                queue.asyncAfter(deadline: .now() + 5) {
                    appLog("srt autotest: done (stream error '\(Self.lastError(stream: true))')")
                }
            }
        }
    }

    // MARK: 녹화 폴더

    /// 설정에서 고른 폴더(외장 저장장치 등)는 보안 범위 접근을 녹화가 끝날 때까지 유지한다
    private var recordingFolder: URL?

    private func newRecordingPath() -> String {
        releaseRecordingFolder()
        recordingFolder = RecordingFolder.resolveChosen()
        let folder = recordingFolder ?? RecordingFolder.defaultFolder

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return folder.appendingPathComponent(formatter.string(from: Date()) + ".mp4").path
    }

    private func releaseRecordingFolder() {
        recordingFolder?.stopAccessingSecurityScopedResource()
        recordingFolder = nil
    }

    static func lastError(stream: Bool) -> String {
        guard let error = core_output_last_error(stream) else { return "" }
        defer { core_free(error) }
        return String(cString: error)
    }
}

/// 계측 오버레이에 붙는 녹화·송출 줄
struct OutputStatusLines: View {
    @ObservedObject var outputs: Outputs

    var body: some View {
        let stats = outputs.stats

        VStack(alignment: .leading, spacing: 2) {
            Text("녹화  " + recordingText(stats))
            Text("송출  " + streamingText(stats))
            Text("인코더 건너뜀 \(stats.encoder_skipped_frames) / \(stats.video_total_frames)")
        }
    }

    private func recordingText(_ stats: core_output_stats) -> String {
        if stats.recording {
            return String(format: "● %@  %@ MB  %.1f fps", clock(stats.recording_seconds), megabytes(stats.recording_bytes), outputs.recordFPS)
        }
        if stats.record_stop_code != 0 && !outputs.recordError.isEmpty {
            return "오류: \(outputs.recordError)"
        }
        return "꺼짐"
    }

    private func streamingText(_ stats: core_output_stats) -> String {
        if stats.stream_reconnecting {
            return "재연결 중…"
        }
        if stats.streaming {
            return String(
                format: "● %@  %.0f kbps  %.1f fps  드롭 %d/%d", clock(stats.streaming_seconds), outputs.streamKbps, outputs.streamFPS,
                stats.stream_dropped_frames, stats.stream_total_frames)
        }
        if outputs.streamPreparing {
            return "YouTube 방송 준비 중…"
        }
        if !outputs.streamPrepareError.isEmpty {
            return "오류: \(outputs.streamPrepareError)"
        }
        if !outputs.streamError.isEmpty {
            return "오류: \(outputs.streamError)"
        }
        return "꺼짐"
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000)
    }
}
