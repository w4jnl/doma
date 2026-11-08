// What the Cards screens write, as events: a card added, edited, shared with the family or
// removed. Every card event carries the owner for the sync filter.
import Foundation

@MainActor
enum CardActions {
    /// The first list colour no card wears yet, or, with all six taken, the next in turn.
    static func nextColour(_ cards: [CardRow]) -> String {
        Tokens.listColours.first { c in !cards.contains { $0.colour == c } } ?? Tokens.listColours[cards.count % Tokens.listColours.count]
    }

    /// The number as the barcode carries it: no spaces, no dashes a person typed between
    /// groups of digits.
    nonisolated static func cleaned(_ value: String) -> String {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) {
            return t.filter(\.isNumber)
        }
        return t
    }

    /// The format a typed number most likely is: 13 digits an EAN-13, 8 an EAN-8, 12 a UPC-A,
    /// 14 an ITF-14, anything else Code 128, which carries any text.
    nonisolated static func guessFormat(for value: String) -> String {
        let v = cleaned(value)
        guard !v.isEmpty, v.allSatisfy(\.isNumber) else { return "code128" }
        switch v.count {
        case 13: return "ean13"
        case 8: return "ean8"
        case 12: return "upca"
        case 14: return "itf14"
        default: return "code128"
        }
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func domain(_ s: String?) -> String? {
        guard var d = s.map(trimmed), !d.isEmpty else { return nil }
        d = d.lowercased()
        if let r = d.range(of: "://") { d = String(d[r.upperBound...]) }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        return d.contains(".") ? d : nil
    }

    @discardableResult
    static func add(name: String, format: String, value: String, domain site: String?, personal: Bool, colour: String, in session: Session) throws -> String? {
        guard let scope = session.scope else { return nil }
        let n = trimmed(name), v = cleaned(value)
        guard !n.isEmpty, !v.isEmpty, Card.formats.contains(format) else { return nil }
        let id = ULID.make()
        try session.record(Kind.cardAdded, CardPayload(cardID: id, ownerPersonID: personal ? scope.personID : nil, name: n, colour: colour, format: format, value: v, domain: domain(site)))
        return id
    }

    static func edit(_ card: CardRow, name: String, format: String, value: String, domain site: String?, in session: Session) throws {
        guard let scope = session.scope else { return }
        let n = trimmed(name), v = cleaned(value)
        guard !n.isEmpty, !v.isEmpty, Card.formats.contains(format) else { return }
        try session.record(Kind.cardEdited, CardPayload(cardID: card.id, ownerPersonID: card.isPersonal ? scope.personID : nil, name: n, colour: card.colour, format: format, value: v, domain: domain(site)))
    }

    static func archive(_ card: CardRow, in session: Session) throws {
        guard let scope = session.scope else { return }
        try session.record(Kind.cardArchived, CardPayload(cardID: card.id, ownerPersonID: card.isPersonal ? scope.personID : nil))
    }

    /// A personal card shared with the family: a household card with the same fields, and the
    /// personal one archived, in one write; the owner stays fixed at creation, as the sync
    /// filter wants it.
    @discardableResult
    static func share(_ card: CardRow, in session: Session) throws -> String? {
        guard card.isPersonal, session.scope != nil else { return nil }
        let id = ULID.make()
        try session.record { events, clock, person in
            events.append(Event(id: id, personID: person, hlc: clock.next(), kind: Kind.cardAdded,
                                payload: CardPayload(cardID: id, ownerPersonID: nil, name: card.name, colour: card.colour, format: card.format, value: card.value, domain: card.domain).jsonValue))
            events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.cardArchived,
                                payload: CardPayload(cardID: card.id, ownerPersonID: person).jsonValue))
        }
        return id
    }
}
