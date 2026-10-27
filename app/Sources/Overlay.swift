import UIKit

/// 메인 스레드에서 MainActor 일을 한다 (이미 메인이면 바로). MainActor가 아닌 Outputs 등이 부른다
func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}

/// 앱 화면 위의 따로 창에 UIKit 화면(알림·공유 창)을 띄운다 (P13). SwiftUI의 .alert·.sheet는 설정 같은 시트가
/// 떠 있으면 그 아래 뷰에서 안 뜨므로, 얼굴 추적 허락 창(P9)처럼 창을 하나 더 만든다
@MainActor
final class OverlayWindow {
    private var window: UIWindow?

    var isShowing: Bool { window != nil }

    /// 앱이 앞에 있을 때만 띄운다. 띄웠으면 true. 닫힐 때(단추·바깥 누름) 부르는 쪽이 `close()`를 부른다
    @discardableResult
    func present(_ controller: UIViewController) -> Bool {
        close(animated: false)
        guard UIApplication.shared.applicationState == .active,
            let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else { return false }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.isHidden = false
        // 아이패드의 공유 창은 팝오버라 붙을 자리가 있어야 한다: 화면 위쪽 가운데
        if let popover = controller.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: 60, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        self.window = window
        root.present(controller, animated: true)
        return true
    }

    /// 단추로 닫힌 경우엔 화면이 이미 내려가 있다. 빈 창이 남아 터치를 막지 않게 꼭 숨긴다
    func close(animated: Bool = true) {
        guard let window else { return }
        self.window = nil
        if let root = window.rootViewController, root.presentedViewController != nil {
            root.dismiss(animated: animated) { window.isHidden = true }
        } else {
            window.isHidden = true
        }
    }
}

/// 녹화·송출이 오류로 멈췄을 때 한 번 알린다 (P13). 상태 줄의 빨간 칩은 다음 시작까지 남는다
enum OutputAlert {
    @MainActor private static let overlay = OverlayWindow()

    /// 어느 스레드에서나 (메인에서 띄운다)
    static func show(title: String, message: String, log: String) {
        appLog("output alert: \(log)")
        onMain { present(title: title, message: message) }
    }

    @MainActor private static func present(title: String, message: String) {
        let alert = UIAlertController(
            title: title, message: message.isEmpty ? "이유를 알 수 없습니다. 로그를 확인하세요." : message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .cancel) { _ in overlay.close() })
        if !overlay.present(alert) { appLog("output alert: not shown (app is not active)") }
    }

    /// CI: 알림이 떠 있으면 닫는다
    @MainActor static func dismissForTest() -> Bool {
        let shown = overlay.isShowing
        overlay.close()
        return shown
    }
}
