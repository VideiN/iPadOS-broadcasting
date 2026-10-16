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

    private var timer: AnyCancellable?
    private var lastStreamBytes: UInt64 = 0
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
        lastStreamBytes = stats.stream_bytes
        lastUpdate = now

        self.stats = stats
        recordError = Self.lastError(stream: false)
        streamError = Self.lastError(stream: true)
        if !stats.recording { recordStopping = false }
        if !stats.streaming { streamStopping = false }
    }

    /// 시작·중지는 인코더 세션을 만들고 닫느라 시간이 걸릴 수 있어 메인 스레드 밖에서 한다
    func toggleRecording() {
        let active = stats.recording
        let force = recordStopping
        if active { recordStopping = true }

        DispatchQueue.global(qos: .userInitiated).async {
            if active {
                core_recording_stop(force)
            } else {
                let path = Self.newRecordingPath()
                let ok = core_recording_start(path)
                appLog("recording start \(ok ? "requested" : "failed"): \(path)")
            }
            DispatchQueue.main.async { self.update() }
        }
    }

    func toggleStreaming(server: String, key: String, kbps: Int) {
        let active = stats.streaming
        let force = streamStopping
        if active { streamStopping = true }

        DispatchQueue.global(qos: .userInitiated).async {
            if active {
                core_streaming_stop(force)
            } else {
                let ok = core_streaming_start(server, key, Int32(kbps))
                appLog("streaming start \(ok ? "requested" : "failed")")
            }
            DispatchQueue.main.async { self.update() }
        }
    }

    /// CI용: `-autotest-output <초> <RTMP 서버 URL>`로 띄우면 입력 소스가 준비된 뒤
    /// 녹화(Documents/Recordings/autotest.mp4)와 송출(스트림 키 "autotest")을 함께 돌리고 멈춘다.
    func runAutotestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-autotest-output"), index + 2 < args.count,
            let seconds = Double(args[index + 1])
        else { return }
        let server = args[index + 2]

        appLog("autotest: recording and streaming for \(seconds) s to \(server)")
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.asyncAfter(deadline: .now() + 3) {
            let recording = core_recording_start(Self.newRecordingPath(name: "autotest"))
            let streaming = core_streaming_start(server, "autotest", 4000)
            appLog("autotest: started (recording \(recording), streaming \(streaming))")

            queue.asyncAfter(deadline: .now() + seconds) {
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

    /// Documents/Recordings. 파일 앱에서 보인다 (UIFileSharingEnabled)
    static func recordingsDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func newRecordingPath(name: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let fileName = (name ?? formatter.string(from: Date())) + ".mp4"
        return recordingsDirectory().appendingPathComponent(fileName).path
    }

    private static func lastError(stream: Bool) -> String {
        guard let error = core_output_last_error(stream) else { return "" }
        defer { core_free(error) }
        return String(cString: error)
    }
}

/// 녹화·송출 버튼과 송출 설정 (P3 확인용. 본 UI는 P4)
struct OutputControls: View {
    @ObservedObject var outputs: Outputs
    @AppStorage("streamServer") private var server = ""
    @AppStorage("streamKey") private var key = ""
    @AppStorage("streamBitrate") private var bitrate = 6000
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                outputs.toggleRecording()
            } label: {
                Label(
                    outputs.recordStopping ? "멈추는 중 (누르면 강제)" : outputs.stats.recording ? "녹화 중지" : "녹화",
                    systemImage: outputs.stats.recording ? "stop.circle.fill" : "record.circle")
            }
            .tint(.red)

            Button {
                if server.isEmpty {
                    showSettings = true
                } else {
                    outputs.toggleStreaming(server: server, key: key, kbps: bitrate)
                }
            } label: {
                Label(
                    outputs.streamStopping ? "멈추는 중 (누르면 강제)" : outputs.stats.streaming ? "송출 중지" : "송출",
                    systemImage: outputs.stats.streaming ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
            }
            .tint(.blue)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .tint(.gray)
            .disabled(outputs.stats.streaming)
        }
        .buttonStyle(.borderedProminent)
        .font(.system(size: 14, weight: .semibold))
        .sheet(isPresented: $showSettings) {
            StreamSettingsView(server: $server, key: $key, bitrate: $bitrate)
        }
    }
}

struct StreamSettingsView: View {
    @Binding var server: String
    @Binding var key: String
    @Binding var bitrate: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("rtmp://… 또는 rtmps://…", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("스트림 키", text: $key)
                } header: {
                    Text("송출 대상")
                } footer: {
                    Text("예: rtmp://live.twitch.tv/app, rtmps://a.rtmps.youtube.com:443/live2. 스트림 키는 이 기기의 앱 설정에 저장됩니다.")
                }

                Section("비디오 (H.264 CBR)") {
                    Stepper("\(bitrate) kbps", value: $bitrate, in: 1000...20000, step: 500)
                }
            }
            .navigationTitle("송출 설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
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
            return "● \(clock(stats.recording_seconds))  \(megabytes(stats.recording_bytes)) MB"
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
                format: "● %@  %.0f kbps  드롭 %d/%d", clock(stats.streaming_seconds), outputs.streamKbps,
                stats.stream_dropped_frames, stats.stream_total_frames)
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
