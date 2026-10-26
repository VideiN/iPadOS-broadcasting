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

    @Published private(set) var streamFPS: Double = 0
    @Published private(set) var recordFPS: Double = 0

    /// 방금 저장한 리플레이 파일 이름 (몇 초 동안 위쪽 막대에 보인다)
    @Published private(set) var replayNotice: String?
    private var lastReplaySavedCount: Int32 = 0

    private var timer: AnyCancellable?
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
        if !stats.recording && !startingRecording && recordingFolder != nil { releaseRecordingFolder() }
        if !stats.streaming { streamStopping = false }
    }

    /// 시작·중지는 인코더 세션을 만들고 닫느라 시간이 걸릴 수 있어 메인 스레드 밖에서 한다
    func toggleRecording() {
        let active = stats.recording
        let force = recordStopping
        if active { recordStopping = true }

        let (video, audio) = Self.recordEncoding()
        let path = active ? "" : newRecordingPath()
        if !active { startingRecording = true }

        DispatchQueue.global(qos: .userInitiated).async {
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
                    self.startingRecording = false
                    if !started { self.releaseRecordingFolder() }
                }
                self.update()
            }
        }
    }

    /// 리플레이 버퍼 켜기·끄기. 저장 위치는 앱의 Recordings 폴더 (고른 외장 폴더는 녹화에만 쓴다)
    func toggleReplay() {
        let active = stats.replay_active
        let defaults = AppSettings.defaults
        let seconds = Int32(defaults.integer(forKey: AppSettings.replaySeconds))
        let maxMB = Int32(defaults.integer(forKey: AppSettings.replayMaxMB))
        let (video, audio) = Self.recordEncoding()
        let directory = RecordingFolder.defaultFolder.path

        DispatchQueue.global(qos: .userInitiated).async {
            if active {
                core_replay_stop()
            } else {
                var video = video
                var audio = audio
                let ok = core_replay_start(directory, seconds, maxMB, &video, &audio)
                appLog("replay buffer start \(ok ? "requested" : "failed")")
            }
            DispatchQueue.main.async { self.update() }
        }
    }

    /// 녹화와 리플레이가 같이 쓰는 인코딩 (설정 › 녹화)
    private static func recordEncoding() -> (core_video_encoding, core_audio_encoding) {
        let settings = EncoderSettings.load(.record)
        let core = Core.shared
        return (settings.video(canvasWidth: core.width, canvasHeight: core.height), settings.audio)
    }

    func saveReplay() {
        DispatchQueue.global(qos: .userInitiated).async { core_replay_save() }
    }

    /// 송출 서버를 아직 정하지 않았거나 YouTube에 로그인하지 않았으면 false (설정을 열어야 함)
    @discardableResult
    func toggleStreaming() -> Bool {
        guard !streamPreparing else { return true }
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
            Task {
                do {
                    let target = try await YouTubeAccount.shared.prepareStream()
                    await MainActor.run {
                        self.startStreaming(
                            server: target.server, key: target.key,
                            encoding: .stream(chzzk: false, canvasHeight: Core.shared.height))
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
            DispatchQueue.global(qos: .userInitiated).async {
                core_streaming_stop(force)
                DispatchQueue.main.async { self.update() }
            }
        } else {
            // 치지직은 스트림 키가 있어야 한다 (없으면 설정을 연다)
            let key = chzzk ? Chzzk.keyStore.load() : StreamKeyStore.load()
            guard !chzzk || !key.isEmpty else { return false }
            streamPrepareError = ""
            startStreaming(server: server, key: key, encoding: .stream(chzzk: chzzk, canvasHeight: Core.shared.height))
        }
        return true
    }

    private func startStreaming(server: String, key: String, encoding: EncoderSettings) {
        let video = Self.streamVideo(encoding)
        let options = StreamOptions.current()
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.start(server: server, key: key, video: video, audio: encoding.audio, options: options)
            appLog("streaming start \(ok ? "requested" : "failed")")
            DispatchQueue.main.async {
                self.streamPreparing = false
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
        queue.asyncAfter(deadline: .now() + 3) {
            var video = recordVideo
            var audio = record.audio
            let recording = core_recording_start(path, &video, &audio)
            let streaming = Self.start(
                server: server, key: key, video: streamVideo, audio: encoding.audio, options: options)
            // 리플레이 버퍼(7초, 목록에 없는 직접 입력 값)는 녹화 인코더를 같이 쓴다. 끝에 저장한다 (P5, P11)
            let replay = core_replay_start(RecordingFolder.defaultFolder.path, 7, 2048, &video, &audio)
            appLog("autotest: started (recording \(recording), streaming \(streaming), replay \(replay))")

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
                    }
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
    private var startingRecording = false

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

    private static func lastError(stream: Bool) -> String {
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
