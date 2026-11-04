// The lock: when the person asked for it in Settings, the app covers itself whenever it comes
// back to the front and asks Face ID, Touch ID or the passcode. The cover is the ground with
// the mark and one button; nothing of the lists shows through. Kept on the device only.
import LocalAuthentication
import SwiftUI

/// How long the app stays open after it went to the background, in seconds; 0 locks at once,
/// `untilTomorrow` locks when the date turns.
enum LockAfter: Int, CaseIterable, Identifiable {
    case immediately = 0, halfMinute = 30, minute = 60, fiveMinutes = 300, quarterHour = 900, hour = 3600, day = 86_400, untilTomorrow = -1

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .immediately: "Immediately"
        case .halfMinute: "30 seconds"
        case .minute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .quarterHour: "15 minutes"
        case .hour: "1 hour"
        case .day: "24 hours"
        case .untilTomorrow: "Until tomorrow"
        }
    }

    /// Whether a return at `now`, after leaving at `left`, has to ask again.
    func due(left: Date, now: Date) -> Bool {
        switch self {
        case .untilTomorrow: !Calendar.current.isDate(left, inSameDayAs: now)
        default: now.timeIntervalSince(left) >= Double(rawValue)
        }
    }
}

struct Lock: ViewModifier {
    @AppStorage("lock.biometrics") private var enabled = false
    @AppStorage("lock.after") private var after = LockAfter.immediately.rawValue
    @Environment(\.scenePhase) private var phase
    @State private var locked = false
    @State private var asking = false
    /// When the app last went to the background; the grace runs from here.
    @State private var left: Date?

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled, locked {
                    cover
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: Tokens.motionBase), value: locked)
            .onAppear {
                // a launch starts locked; the ask follows once the scene is active
                if enabled, !UITestHooks.testing { locked = true }
            }
            // the Face ID sheet itself takes the app to inactive and back, so only background
            // locks, and only a locked app asks on return
            .onChange(of: phase) { _, now in
                guard enabled else { locked = false; return }
                switch now {
                case .background:
                    if left == nil { left = Date() }
                case .active:
                    // back within the grace: stay open; past it, or at launch: ask
                    if let left, !locked {
                        let grace = LockAfter(rawValue: after) ?? .immediately
                        if grace.due(left: left, now: Date()) { locked = true }
                    }
                    left = nil
                    if locked { unlock() }
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
