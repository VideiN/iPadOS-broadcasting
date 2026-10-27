import Combine
import SwiftUI
import UIKit

/// 계측 오버레이 (계획 11장): 렌더 fps, 프레임 시간, GPU 시간, 지연 프레임, 메모리, 발열, 입력 상태
struct DiagnosticsOverlay: View {
    @ObservedObject var diagnostics: Diagnostics
    let outputs: Outputs

    var body: some View {
        let stats = diagnostics.stats

        VStack(alignment: .leading, spacing: 2) {
            BuildOverlayLine()
            Text(String(format: stats.target_fps.rounded() == stats.target_fps ? "FPS   %5.1f / %.0f" : "FPS   %5.1f / %.2f", stats.active_fps, stats.target_fps))
            Text(String(format: "렌더  %5.2f ms", stats.frame_time_ms))
            Text(String(format: "GPU   %5.2f ms/프레임", diagnostics.gpuMillisecondsPerFrame))
            Text("지연  \(stats.lagged_frames) / \(stats.total_frames) 프레임")
            Text("메모리 \(megabytes(stats.memory_footprint)) MB (여유 \(megabytes(stats.memory_available)) MB)")
            Text("발열  \(diagnostics.thermalState)")
            Text("카메라 \(cameraSize(stats))")
            // 섞은 소리(송출·녹화로 나가는 것, 마스터 볼륨 뒤). 마이크 입력만이 아니다 (P13)
            HStack(alignment: .top, spacing: 6) {
                Text("출력")
                VStack(alignment: .leading, spacing: 2) {
                    channelMeter("L", stats.master_peak_left_db)
                    channelMeter("R", stats.master_peak_right_db)
                }
            }
            OutputStatusLines(outputs: outputs)
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func megabytes(_ bytes: UInt64) -> UInt64 {
        bytes / 1024 / 1024
    }

    private func cameraSize(_ stats: core_stats) -> String {
        stats.camera_width > 0
            ? String(format: "%ux%u  %.1f fps", stats.camera_width, stats.camera_height, stats.camera_fps) : "프레임 없음"
    }

    private func channelMeter(_ channel: String, _ db: Float) -> some View {
        HStack(spacing: 6) {
            Text("\(channel) \(peakText(db))")
            AudioMeter(peak: db)
        }
    }

    private func peakText(_ db: Float) -> String {
        db.isFinite ? String(format: "%6.1f dB", db) : "   무음"
    }
}

/// -60 dB ~ 0 dB 막대. -9 dB 위는 노랑, -3 dB 위는 빨강
struct AudioMeter: View {
    let peak: Float

    var body: some View {
        let level = peak.isFinite ? CGFloat(min(max((peak + 60) / 60, 0), 1)) : 0

        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.2))
            Capsule()
                .fill(peak > -3 ? Color.red : peak > -9 ? Color.yellow : Color.green)
                .frame(width: 100 * level)
        }
        .frame(width: 100, height: 8)
    }
}

final class Diagnostics: ObservableObject {
    @Published private(set) var stats = core_stats()
    @Published private(set) var thermalState = "-"

    private var timer: AnyCancellable?
    private var lastLog = Date.distantPast

    init() {
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.update() }
    }

    var gpuMillisecondsPerFrame: Double {
        stats.active_fps > 0 ? stats.gpu_ms_per_second / stats.active_fps : 0
    }

    private func update() {
        guard Core.shared.isRunning else { return }

        var stats = core_stats()
        core_get_stats(&stats)
        self.stats = stats
        self.thermalState = Self.describe(ProcessInfo.processInfo.thermalState)

        // 같은 값을 5초마다 로그로도 남긴다
        if Date().timeIntervalSince(lastLog) >= 5 {
            lastLog = Date()
            let output = Outputs.shared.stats
            appLog(
                String(
                    format:
                        "[stats] fps=%.1f frame_ms=%.2f gpu_ms=%.2f lagged=%u/%u mem=%lluMB avail=%lluMB thermal=%@ camera=%ux%u camera_fps=%.1f audio_peak=%.1f/%.1fdB master_peak=%.1f/%.1fdB rec=%d rec_fps=%.1f stream=%d stream_kbps=%.0f stream_fps=%.1f dropped=%d/%d enc_skipped=%u/%u",
                    stats.active_fps, stats.frame_time_ms, gpuMillisecondsPerFrame, stats.lagged_frames,
                    stats.total_frames, stats.memory_footprint / 1024 / 1024, stats.memory_available / 1024 / 1024,
                    thermalState, stats.camera_width, stats.camera_height, stats.camera_fps, stats.audio_peak_left_db,
                    stats.audio_peak_right_db, stats.master_peak_left_db, stats.master_peak_right_db,
                    output.recording ? 1 : 0, Outputs.shared.recordFPS, output.streaming ? 1 : 0, Outputs.shared.streamKbps,
                    Outputs.shared.streamFPS,
                    output.stream_dropped_frames, output.stream_total_frames, output.encoder_skipped_frames,
                    output.video_total_frames))
        }
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "정상"
        case .fair: "약간 높음"
        case .serious: "높음"
        case .critical: "위험"
        @unknown default: "알 수 없음"
        }
    }
}
