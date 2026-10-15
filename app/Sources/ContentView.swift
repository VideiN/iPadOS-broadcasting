import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var diagnostics = Diagnostics()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            PreviewView()
                .aspectRatio(CGFloat(Core.shared.width) / CGFloat(Core.shared.height), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            DiagnosticsOverlay(diagnostics: diagnostics)
                .padding(12)
        }
        .onAppear {
            // 방송 중 화면 자동 잠금을 막는다 (계획 5.4)
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}

/// 계측 오버레이 (계획 11장): 렌더 fps, 프레임 시간, GPU 시간, 지연 프레임, 메모리, 발열
struct DiagnosticsOverlay: View {
    @ObservedObject var diagnostics: Diagnostics

    var body: some View {
        let stats = diagnostics.stats

        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "FPS   %5.1f / %.0f", stats.active_fps, stats.target_fps))
            Text(String(format: "렌더  %5.2f ms", stats.frame_time_ms))
            Text(String(format: "GPU   %5.2f ms/프레임", diagnostics.gpuMillisecondsPerFrame))
            Text("지연  \(stats.lagged_frames) / \(stats.total_frames) 프레임")
            Text("메모리 \(megabytes(stats.memory_footprint)) MB (여유 \(megabytes(stats.memory_available)) MB)")
            Text("발열  \(diagnostics.thermalState)")
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func megabytes(_ bytes: UInt64) -> UInt64 {
        bytes / 1024 / 1024
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
            print(
                String(
                    format: "[stats] fps=%.1f frame_ms=%.2f gpu_ms=%.2f lagged=%u/%u mem=%lluMB avail=%lluMB thermal=%@",
                    stats.active_fps, stats.frame_time_ms, gpuMillisecondsPerFrame, stats.lagged_frames,
                    stats.total_frames, stats.memory_footprint / 1024 / 1024, stats.memory_available / 1024 / 1024,
                    thermalState))
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
