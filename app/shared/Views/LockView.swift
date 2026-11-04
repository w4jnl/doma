// The lock: when the person asked for it in Settings, the app covers itself whenever it comes
// back to the front and asks Face ID, Touch ID or the passcode. The cover is the ground with
// the mark and one button; nothing of the lists shows through. Kept on the device only.
import LocalAuthentication
import SwiftUI

struct Lock: ViewModifier {
    @AppStorage("lock.biometrics") private var enabled = false
    @Environment(\.scenePhase) private var phase
    @State private var locked = false
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled, locked {
                    cover
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: Tokens.motionBase), value: locked)
            .onChange(of: phase, initial: true) { _, now in
                guard enabled else { locked = false; return }
                switch now {
                case .background:
                    locked = true
                case .active:
                    if locked || !UITestHooks.testing { unlock() }
                default:
                    break
                }
            }
            .onChange(of: enabled) { _, on in if !on { locked = false } }
    }

    private var cover: some View {
        ZStack {
            Tokens.ground.ignoresSafeArea()
            VStack(spacing: Tokens.space5) {
                Mark(size: 48)
                Button {
                    unlock()
                } label: {
                    Label("Unlock", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    /// One ask at a time; a failure keeps the cover and the button.
    private func unlock() {
        guard !asking, !UITestHooks.testing else { return }
        locked = true
        asking = true
        let ctx = LAContext()
        ctx.localizedCancelTitle = String(localized: "Cancel")
        Task { @MainActor in
            defer { asking = false }
            do {
                let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock doma"))
                if ok { locked = false }
            } catch {
                // stays locked; the button asks again
            }
        }
    }
}

extension View {
    func lockable() -> some View { modifier(Lock()) }
}
