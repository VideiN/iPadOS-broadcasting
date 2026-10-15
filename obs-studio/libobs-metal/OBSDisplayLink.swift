/******************************************************************************
 iOS port: replacement for CVDisplayLink, which only exists on macOS.

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
import QuartzCore

/// Calls a callback for every screen refresh, using a `CADisplayLink` on a dedicated thread
///
/// The thread keeps presentation independent of the app's main thread. On ProMotion displays the refresh rate is
/// variable, so the frame rate is pinned to the output frame rate of `libobs` to avoid uneven frame pacing.
final class OBSDisplayLink: NSObject {
    private let callback: () -> Void
    private let lock = NSLock()
    private var thread: Thread?
    private var targetFrameRate: Float = 60
    private var appliedFrameRate: Float = 0

    init(callback: @escaping () -> Void) {
        self.callback = callback
        super.init()
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard thread == nil else { return }

        let thread = Thread(target: self, selector: #selector(run), object: nil)
        thread.name = "libobs-metal display link"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        thread?.cancel()
        thread = nil
    }

    func setFrameRate(_ frameRate: Float) {
        lock.lock()
        defer { lock.unlock() }

        targetFrameRate = frameRate
    }

    @objc private func run() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .current, forMode: .common)

        while !Thread.current.isCancelled {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        link.invalidate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        lock.lock()
        let frameRate = targetFrameRate
        lock.unlock()

        if frameRate != appliedFrameRate {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: frameRate, maximum: frameRate, preferred: frameRate)
            appliedFrameRate = frameRate
        }

        callback()
    }
}
#endif
