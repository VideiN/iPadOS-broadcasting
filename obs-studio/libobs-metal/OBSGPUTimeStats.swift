/******************************************************************************
 iOS port: GPU time statistics for the app's diagnostics overlay.

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 ******************************************************************************/

#if os(iOS)
import Foundation
import Metal

/// Sums up the GPU execution time of completed command buffers in one-second windows
///
/// Command buffers can overlap on the GPU, so the sum is an upper bound of the time the GPU was busy.
final class OBSGPUTimeStats {
    static let shared = OBSGPUTimeStats()

    private let lock = NSLock()
    private var windowStart: CFTimeInterval = 0
    private var busyInWindow: CFTimeInterval = 0
    private var lastBusy: CFTimeInterval = 0
    private var lastDuration: CFTimeInterval = 0

    /// Adds the GPU time of a completed command buffer
    func record(_ commandBuffer: MTLCommandBuffer) {
        let start = commandBuffer.gpuStartTime
        let end = commandBuffer.gpuEndTime

        guard end > start else { return }

        lock.lock()
        defer { lock.unlock() }

        if windowStart == 0 {
            windowStart = start
        }

        busyInWindow += end - start

        if end - windowStart >= 1.0 {
            lastBusy = busyInWindow
            lastDuration = end - windowStart
            busyInWindow = 0
            windowStart = end
        }
    }

    /// GPU time in milliseconds per second of the last completed window
    var busyMillisecondsPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }

        guard lastDuration > 0 else { return 0 }

        return lastBusy / lastDuration * 1000
    }
}

/// Returns the GPU time in milliseconds per second of the last completed one-second window
@_cdecl("libobs_metal_gpu_busy_ms_per_second")
public func libobs_metal_gpu_busy_ms_per_second() -> Double {
    OBSGPUTimeStats.shared.busyMillisecondsPerSecond
}
#endif
