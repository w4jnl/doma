// An invite as it arrives: the QR's link, the app link the invite page offers, a pasted link,
// or the bare code. The token rides in the fragment of the app link so it never lands in a log.
import Foundation

struct InviteLink: Hashable, Sendable {
    /// The server the invite is for; nil for the app link and a bare code, which name none.
    var server: URL?
    var token: String

    static let tokenCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// Reads "https://host/i/<token>", "doma://invite#<token>", "doma://invite/<token>" or
    /// "<token>". Anything else is nil.
    init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let url = URL(string: s), let scheme = url.scheme?.lowercased() {
            if scheme == "doma" {
                let t = url.fragment ?? url.lastPathComponent
                guard Self.isToken(t) else { return nil }
                self.init(server: nil, token: t)
                return
            }
            if scheme == "https" || scheme == "http", let host = url.host, url.pathComponents.count == 3, url.pathComponents[1] == "i" {
                let t = url.pathComponents[2]
                guard Self.isToken(t) else { return nil }
                var c = URLComponents()
                c.scheme = scheme
                c.host = host
                c.port = url.port
                self.init(server: c.url, token: t)
                return
            }
            return nil
        }
        guard Self.isToken(s) else { return nil }
        self.init(server: nil, token: s)
    }

    init(server: URL?, token: String) {
        self.server = server
        self.token = token
    }

    static func isToken(_ t: String) -> Bool {
        t.count >= 16 && t.count <= 128 && t.unicodeScalars.allSatisfy { tokenCharacters.contains($0) }
    }
}
