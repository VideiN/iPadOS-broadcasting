import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var core = Core.shared
    @ObservedObject private var outputs = Outputs.shared
    @StateObject private var diagnostics = Diagnostics()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if core.isRunning {
                PreviewView()
                    .aspectRatio(CGFloat(core.width) / CGFloat(core.height), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(core.failed ? "libobs를 시작하지 못했습니다. 로그를 확인하세요." : "libobs 시작 중…")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            DiagnosticsOverlay(diagnostics: diagnostics, outputs: outputs)
                .padding(12)

            if core.isRunning {
                VStack(alignment: .trailing, spacing: 8) {
                    InputPicker(core: core)
                    OutputControls(outputs: outputs)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
        .onAppear {
            appLog("content appeared")
            // 방송 중 화면 자동 잠금을 막는다 (계획 5.4)
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}

/// 카메라·오디오 입력 선택 (P2 확인용. 본 UI는 P4)
struct InputPicker: View {
    @ObservedObject var core: Core

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Menu {
                Picker(
                    "카메라",
                    selection: Binding(
                        get: { core.currentCamera },
                        set: { core.select(CORE_DEVICE_CAMERA, $0) })
                ) {
                    ForEach(core.cameras) { device in
                        Text(itemName(device)).tag(device.id).selectionDisabled(!device.available)
                    }
                }
            } label: {
                Label(
                    label(of: core.currentCamera, in: core.cameras, empty: "카메라 없음", disconnected: "연결 끊김"),
                    systemImage: "video")
            }

            Menu {
                Picker(
                    "오디오 입력",
                    selection: Binding(
                        get: { core.currentAudioInput },
                        set: { core.select(CORE_DEVICE_AUDIO_INPUT, $0) })
                ) {
                    ForEach(core.audioInputs) { device in
                        Text(device.id.isEmpty ? "시스템 기본" : itemName(device)).tag(device.id)
                            .selectionDisabled(!device.available)
                    }
                }
            } label: {
                // 고른 장치가 빠지면 오디오는 시스템 기본 경로로 녹음하다가, 다시 꽂으면 돌아간다 (ios-audio-input)
                Label(
                    label(
                        of: core.currentAudioInput, in: core.audioInputs, empty: "시스템 기본",
                        disconnected: "연결 끊김, 시스템 기본 사용 중"),
                    systemImage: "mic")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func itemName(_ device: Device) -> String {
        device.available ? device.name : "\(device.name) (연결 끊김)"
    }

    private func label(of id: String, in devices: [Device], empty: String, disconnected: String) -> String {
        if id.isEmpty { return empty }
        guard let device = devices.first(where: { $0.id == id }) else { return id }
        return device.available ? device.name : "\(device.name) (\(disconnected))"
    }
}

/// 계측 오버레이 (계획 11장): 렌더 fps, 프레임 시간, GPU 시간, 지연 프레임, 메모리, 발열, 입력 상태
struct DiagnosticsOverlay: View {
    @ObservedObject var diagnostics: Diagnostics
    let outputs: Outputs

    var body: some View {
        let stats = diagnostics.stats

        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "FPS   %5.1f / %.0f", stats.active_fps, stats.target_fps))
            Text(String(format: "렌더  %5.2f ms", stats.frame_time_ms))
            Text(String(format: "GPU   %5.2f ms/프레임", diagnostics.gpuMillisecondsPerFrame))
            Text("지연  \(stats.lagged_frames) / \(stats.total_frames) 프레임")
            Text("메모리 \(megabytes(stats.memory_footprint)) MB (여유 \(megabytes(stats.memory_available)) MB)")
            Text("발열  \(diagnostics.thermalState)")
            Text("카메라 \(cameraSize(stats))")
            HStack(spacing: 6) {
                Text("오디오 \(peakText(stats.audio_peak_db))")
                AudioMeter(peak: stats.audio_peak_db)
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
        stats.camera_width > 0 ? "\(stats.camera_width)x\(stats.camera_height)" : "프레임 없음"
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
                        "[stats] fps=%.1f frame_ms=%.2f gpu_ms=%.2f lagged=%u/%u mem=%lluMB avail=%lluMB thermal=%@ camera=%ux%u audio_peak=%.1fdB rec=%d stream=%d stream_kbps=%.0f dropped=%d/%d enc_skipped=%u",
                    stats.active_fps, stats.frame_time_ms, gpuMillisecondsPerFrame, stats.lagged_frames,
                    stats.total_frames, stats.memory_footprint / 1024 / 1024, stats.memory_available / 1024 / 1024,
                    thermalState, stats.camera_width, stats.camera_height, stats.audio_peak_db,
                    output.recording ? 1 : 0, output.streaming ? 1 : 0, Outputs.shared.streamKbps,
                    output.stream_dropped_frames, output.stream_total_frames, output.encoder_skipped_frames))
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
