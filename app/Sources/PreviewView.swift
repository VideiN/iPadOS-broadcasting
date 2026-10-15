import QuartzCore
import SwiftUI
import UIKit

/// libobs 프리뷰를 그리는 SwiftUI 뷰
struct PreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalPreviewView {
        MetalPreviewView()
    }

    func updateUIView(_ uiView: MetalPreviewView, context: Context) {}
}

/// CAMetalLayer를 기본 레이어로 쓰는 뷰. libobs-metal이 이 레이어에 프리뷰를 내보낸다.
final class MetalPreviewView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var display: UnsafeMutableRawPointer?

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if let window {
            contentScaleFactor = window.traitCollection.displayScale
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = UInt32(max(bounds.width * contentScaleFactor, 1))
        let height = UInt32(max(bounds.height * contentScaleFactor, 1))

        if let display {
            core_display_resize(display, width, height)
        } else if window != nil, Core.shared.isRunning, bounds.width > 0, bounds.height > 0 {
            display = core_display_create(Unmanaged.passUnretained(self).toOpaque(), width, height)
            appLog("display created \(width)x\(height): \(display != nil)")
        }
    }

    deinit {
        if let display {
            core_display_destroy(display)
        }
    }
}
