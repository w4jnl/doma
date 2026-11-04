// MicButton is the mic at the end of the add field: a tap listens, or stops; held on the phone,
// or right-clicked on the Mac, it chooses the language, whose code (EN, NL, SK) shows under it.
// While it listens the glyph is filled and pulses in `out`, the one colour the app already uses
// for something that wants a look; while the model is fetched, once, it is a spinner.
import SwiftUI

struct MicButton: View {
    let listener: Listener
    /// tap listens or stops; pick chooses the language and listens in it.
    var tap: () -> Void
    var pick: (Language) -> Void
    @AppStorage(Language.key) private var stored = ""

    /// The language the mic listens in: the one chosen, else the device's; English under a test,
    /// so the pictures are the same on every machine.
    private var language: Language {
        if UITestHooks.testing { return .english }
        return Language(rawValue: stored) ?? Language.remembered
    }

    var body: some View {
        #if os(iOS)
        Menu {
            picker
        } label: {
            face
        } primaryAction: {
            tap()
        }
        .accessibilityIdentifier("mic")
        .accessibilityLabel(label)
        #else
        Button(action: tap) { face }
            .buttonStyle(.plain)
            .contextMenu { picker }
            .help(label)
            .accessibilityIdentifier("mic")
            .accessibilityLabel(label)
        #endif
    }

    private var picker: some View {
        Picker("Language", selection: Binding(get: { language }, set: { pick($0) })) {
            ForEach(Language.allCases) { Text($0.name).tag($0) }
        }
    }

    private var label: Text {
        listener.busy ? Text("Stop listening") : Text("Say an item, in \(language.name)")
    }

    private var face: some View {
        VStack(spacing: 1) {
            Group {
                switch listener.state {
                case .preparing:
                    ProgressView().controlSize(.small)
                case .listening:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(Tokens.out)
                        .symbolEffect(.pulse, options: .repeating)
                default:
                    Image(systemName: "mic").foregroundStyle(Tokens.accent)
                }
            }
            .font(.body)
            .frame(height: 20)
            Text(language.short)
                .font(Tokens.mono(fixed: 9, bold: true))
                .foregroundStyle(Tokens.inkMuted)
        }
        .frame(width: Tokens.rowH, height: Self.height)
        .contentShape(Rectangle())
    }

    /// The bar's height on the phone; the compact row's on the Mac, so the add row keeps it.
    private static var height: CGFloat {
        #if os(macOS)
        Tokens.rowHCompact
        #else
        Tokens.rowH
        #endif
    }
}
