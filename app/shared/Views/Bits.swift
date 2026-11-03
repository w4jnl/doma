// The small pieces every screen shares: the offline badge, the armed button for anything
// destructive, relative times, the hairline, the glyph with its word.
import SwiftUI

/// One small badge in the toolbar when the last sync did not reach the server; never an alert.
struct OfflineBadge: View {
    @Environment(Session.self) private var session

    var body: some View {
        if session.syncer.offline {
            HStack(spacing: Tokens.space1) {
                Text(verbatim: Tokens.Glyph.unknown)
                Text("offline")
            }
            .font(.footnote)
            .foregroundStyle(Tokens.inkMuted)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("offline"))
            .accessibilityIdentifier("offline")
        }
    }
}

/// A destructive action arms in place: the first tap turns the button into "Really …?", the
/// second does it, and it disarms by itself after a few seconds.
struct ArmedButton: View {
    var title: LocalizedStringKey
    var armedTitle: LocalizedStringKey
    var role: ButtonRole? = .destructive
    var action: () -> Void
    @State private var armed = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button(role: armed ? role : nil) {
            if armed {
                armed = false
                disarm?.cancel()
                action()
            } else {
                armed = true
                disarm?.cancel()
                disarm = Task {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { armed = false }
                }
            }
        } label: {
            if armed {
                Text(armedTitle)
                    .foregroundStyle(Tokens.onOut)
                    .padding(.horizontal, Tokens.space2)
                    .padding(.vertical, Tokens.space1)
                    .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
            } else {
                Text(title)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(armed ? Tokens.onOut : Tokens.accent)
        .accessibilityHint(armed ? Text("Tap again to confirm") : Text(""))
    }
}

/// "3 wk ago", "yesterday", "in 2 days", with the absolute time for VoiceOver and on hover.
struct RelativeText: View {
    var millis: Int64
    @Environment(\.locale) private var locale

    /// What "now" is; the snapshot tests pin it.
    nonisolated(unsafe) static var now: @Sendable () -> Date = { Date() }

    var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    var body: some View {
        Text(Self.string(for: date, locale: locale))
            .font(Tokens.mono(.footnote))
            .foregroundStyle(Tokens.inkMuted)
            .help(Text(date, format: .dateTime))
            .accessibilityLabel(Text(date, format: .dateTime.day().month().hour().minute()))
    }

    static func string(for date: Date, locale: Locale) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: now())
    }
}

/// A glyph and its word, as every state is shown; never colour alone.
struct GlyphLabel: View {
    var glyph: String
    var word: LocalizedStringKey
    var color: Color = Tokens.inkMuted

    var body: some View {
        HStack(spacing: Tokens.space1) {
            Text(verbatim: glyph)
            Text(word)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// A line of help under a title, in the voice of the design system.
struct HelpLine: View {
    var text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Tokens.inkMuted)
            .multilineTextAlignment(.center)
    }
}

/// One line for what went wrong, next to the thing; no apologies, no codes.
struct ProblemLine: View {
    var text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Tokens.out)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// Row height from the tokens, taller in shop mode.
    func rowHeight(shop: Bool = false) -> some View {
        frame(minHeight: shop ? Tokens.rowHShop : Tokens.rowH)
    }
}

/// The app's version for About.
enum AppInfo {
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}

/// The dot before a list's name, in the list's colour; the default list wears the accent.
struct ListDot: View {
    var colour: String

    var body: some View {
        Circle()
            .fill(Tokens.listColor(colour))
            .frame(width: Tokens.space3, height: Tokens.space3)
            .accessibilityHidden(true)
    }
}

/// The six list colours as a row of dots; the chosen one wears a ring in ink.
struct ColourDots: View {
    @Binding var colour: String

    var body: some View {
        HStack(spacing: Tokens.space3) {
            ForEach(Tokens.listColours, id: \.self) { c in
                Button {
                    colour = c
                } label: {
                    Circle()
                        .fill(Tokens.listColor(c))
                        .frame(width: Tokens.space5, height: Tokens.space5)
                        .padding(Tokens.space1)
                        .overlay(Circle().strokeBorder(Tokens.ink, lineWidth: colour == c ? 2 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.name(c))
                .accessibilityAddTraits(colour == c ? [.isSelected] : [])
            }
        }
    }

    static func name(_ c: String) -> Text {
        switch c {
        case "list-1": Text("Teal")
        case "list-2": Text("Sky")
        case "list-3": Text("Violet")
        case "list-4": Text("Plum")
        case "list-5": Text("Gold")
        default: Text("Moss")
        }
    }
}
