// Shake to clear on the phone: a window-level motion event, reported to the list on screen.
#if os(iOS)
import SwiftUI
import UIKit

extension View {
    func onShake(_ action: @escaping () -> Void) -> some View {
        background(ShakeCatcher(action: action))
    }
}

private struct ShakeCatcher: UIViewControllerRepresentable {
    var action: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.action = action
        return c
    }

    func updateUIViewController(_ c: Controller, context: Context) {
        c.action = action
    }

    final class Controller: UIViewController {
        var action: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { action?() }
            super.motionEnded(motion, with: event)
        }
    }
}
#endif
