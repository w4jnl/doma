// Every screen as a picture, light and dark at two Dynamic Type sizes, against the PNGs under
// Snapshots/<platform>. make snapshots records them (tmp/record-snapshots); make mac-test and
// make ios-test compare, allowing one pixel in a hundred to differ for the renderer's own
// drift. The data is seeded, and "now" is pinned, so a picture does not change with the day.
// A recording notes the OS it was made on (recorded.json); on another major version the
// comparison is skipped, because glass, forms and type render differently there and a diff
// would say nothing about the app.
import SwiftUI
import XCTest
@testable import Doma
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
final class SnapshotTests: XCTestCase {
    #if os(iOS)
    nonisolated static let platform = "ios"
    static let size = CGSize(width: 393, height: 852)
    #else
    nonisolated static let platform = "macos"
    static let size = CGSize(width: 900, height: 600)
    #endif
    nonisolated static let dir = Fixture.root.appendingPathComponent("app/shared/Tests/Snapshots/" + platform)
    static let recording = FileManager.default.fileExists(atPath: Fixture.root.appendingPathComponent("tmp/record-snapshots").path)
    /// Where a recording lands: the repository on the simulator; on the Mac the sandboxed app
    /// cannot write there, so its temp folder, from where make snapshots copies the files.
    static var recordDir: URL {
        #if os(iOS)
        dir
        #else
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doma-snapshots", isDirectory: true)
        #endif
    }
    nonisolated static let now = Date(timeIntervalSince1970: 1_793_500_000) // 2026-11-01
    static let tolerance = 0.01

    var session: Session!
    var shopping = ""
    var weekend = ""

    /// The OS this runs on, as the recording notes it.
    nonisolated static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The major version the pictures were recorded on, from recorded.json next to them.
    nonisolated static var recordedMajor: Int? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("recorded.json")),
              let v = try? JSONValue(data: data), let os = v["os"]?.stringValue else { return nil }
        return os.split(separator: ".").first.flatMap { Int($0) }
    }

    override func setUp() async throws {
        RelativeText.now = { Self.now }
        UITestHooks.noCamera = true
        let store = try DomaStore.inMemory()
        try store.saveContext(ServerContext(serverID: "S1", baseURL: URL(string: "https://doma.example")!, credentialID: "C1", personID: "pa", displayName: "Jaro", createdAt: 1))
        try store.upsertHousehold(HouseholdRow(serverID: "S1", id: "H1", name: "De Vries", timezone: "Europe/Amsterdam", stalenessDays: 14, role: "owner"))
        session = Session(store: store)
        let t = millis(Self.now) - 3 * 86_400_000
        var wall = t
        func ev(_ id: String, _ kind: String, _ p: some Encodable) -> SyncEvent {
            wall += 1000
            return SyncEvent(seq: Int64(wall / 1000), id: id, personID: "pa", hlc: "\(wall):0:a", kind: kind, payload: p.jsonValue)
        }
        shopping = "L1"
        weekend = "L2"
        try store.applyRemote([
            ev("l1", Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true)),
            ev("l2", Kind.listCreated, ListPayload(listID: "L2", name: "Weekend", colour: "list-4", ownerPersonID: "pa")),
            ev("h1", Kind.homeCreated, HomePayload(homeID: "G", name: "Gouda")),
            ev("i1", Kind.itemNamed, ItemPayload(itemID: "I1", name: "melk")),
            ev("i2", Kind.itemNamed, ItemPayload(itemID: "I2", name: "brood")),
            ev("i3", Kind.itemNamed, ItemPayload(itemID: "I3", name: "eieren")),
            ev("i4", Kind.itemNamed, ItemPayload(itemID: "I4", name: "koffie")),
            ev("i5", Kind.itemNamed, ItemPayload(itemID: "I5", name: "olijfolie")),
            ev("e5", Kind.entryAdded, EntryPayload(listID: "L1", itemID: "I5")),
            ev("c5", Kind.entryChecked, EntryPayload(listID: "L1", itemID: "I5")),
            ev("x1", Kind.entryCleared, EntryPayload(listID: "L1", beforeHLC: "\(wall + 500):0:a")),
            ev("e1", Kind.entryAdded, EntryPayload(listID: "L1", itemID: "I1", qty: 2, unit: "x")),
            ev("e2", Kind.entryAdded, EntryPayload(listID: "L1", itemID: "I2", forHomeID: "G")),
            ev("e3", Kind.entryAdded, EntryPayload(listID: "L1", itemID: "I3", note: "vrije uitloop", qty: 12, unit: "x")),
            ev("e4", Kind.entryAdded, EntryPayload(listID: "L1", itemID: "I4", qty: 500, unit: "g")),
            ev("c4", Kind.entryChecked, EntryPayload(listID: "L1", itemID: "I4")),
            ev("e6", Kind.entryAdded, EntryPayload(listID: "L2", itemID: "I1")),
        ], scope: session.scope!, clock: nil)
    }

    override func tearDown() {
        RelativeText.now = { Date() }
        UITestHooks.noCamera = false
        UserDefaults.standard.removeObject(forKey: "shop." + shopping)
    }

    func family() -> FamilyModel {
        let day: Int64 = 86_400_000
        let now = millis(Self.now)
        return FamilyModel(session: session,
                           members: [Member(personID: "pa", displayName: "Jaro", role: "owner", joinedAt: now - 30 * day, lastSeenAt: now - 60_000),
                                     Member(personID: "pb", displayName: "Sam", role: "member", joinedAt: now - 20 * day, lastSeenAt: now - 2 * day)],
                           invites: [Invite(id: "inv", role: "member", expiresAt: now + 6 * day, url: nil)],
                           guests: [GuestLink(id: "g", label: "The neighbours", homeID: "G", listID: "L1", expiresAt: now + 3 * day, active: true, url: "https://doma.example/g/abc")],
                           devices: [Credential(id: "C1", label: "Jaro's iPhone", platform: "ios", createdAt: now - 30 * day, lastUsedAt: now, hasPush: true),
                                     Credential(id: "C2", label: "Jaro's Mac", platform: "macos", createdAt: now - 10 * day, lastUsedAt: now - day, hasPush: false)])
    }

    func testScan() async throws {
        try await check("scan") { ScanView() }
    }

    func testLists() async throws {
        try await check("lists") { NavigationStack { ListsView() } }
    }

    func testList() async throws {
        let id = shopping
        try await check("list") { NavigationStack { ListView(listID: id) } }
    }

    func testListInShopMode() async throws {
        let id = shopping
        UserDefaults.standard.set(true, forKey: "shop." + id)
        try await check("list-shop") { NavigationStack { ListView(listID: id) } }
    }

    func testFamily() async throws {
        let m = family()
        try await check("family") { NavigationStack { FamilyView(preset: m) } }
    }

    func testSettings() async throws {
        let m = family()
        try await check("settings") { NavigationStack { SettingsView(model: m) } }
    }

    func testInvite() async throws {
        let inv = Invite(id: "inv", role: "member", expiresAt: millis(Self.now) + 7 * 86_400_000, url: "https://doma.example/i/abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG")
        try await check("invite") { NavigationStack { InviteSheet(invite: inv) } }
    }

    #if os(macOS)
    func testMacMain() async throws {
        try await check("main") { MacMainView() }
    }
    #else
    func testTabs() async throws {
        try await check("main") { MainView() }
    }
    #endif

    // MARK: The harness

    func check(_ name: String, @ViewBuilder _ view: @escaping @MainActor () -> some View, file: StaticString = #filePath, line: UInt = #line) async throws {
        if !Self.recording, let major = Self.recordedMajor, major != ProcessInfo.processInfo.operatingSystemVersion.majorVersion {
            throw XCTSkip("the pictures were recorded on \(Self.platform) \(major); this is \(Self.osVersion)")
        }
        if Self.recording {
            try FileManager.default.createDirectory(at: Self.recordDir, withIntermediateDirectories: true)
            try Data("{\"os\": \"\(Self.osVersion)\"}\n".utf8).write(to: Self.recordDir.appendingPathComponent("recorded.json"))
        }
        for dark in [false, true] {
            for (sizeName, size) in [("L", DynamicTypeSize.large), ("XXXL", DynamicTypeSize.xxxLarge)] {
                let full = "\(name)-\(dark ? "dark" : "light")-\(sizeName)"
                let content = AnyView(view()
                    .environment(session)
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.locale, Locale(identifier: "en"))
                    .tint(Tokens.accent))
                let png = try await render(content, dark: dark)
                try compare(png, name: full, file: file, line: line)
            }
        }
    }

    func compare(_ png: Data, name: String, file: StaticString, line: UInt) throws {
        let url = Self.dir.appendingPathComponent(name + ".png")
        if Self.recording || !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: Self.recordDir, withIntermediateDirectories: true)
            try png.write(to: Self.recordDir.appendingPathComponent(name + ".png"))
            if !Self.recording {
                XCTFail("\(name): no snapshot yet; make snapshots records it", file: file, line: line)
            }
            return
        }
        let want = try Data(contentsOf: url)
        let a = try XCTUnwrap(Self.pixels(png)), b = try XCTUnwrap(Self.pixels(want))
        var diff = 0
        if a.width != b.width || a.height != b.height {
            diff = a.width * a.height
        } else {
            for i in stride(from: 0, to: a.bytes.count, by: 4) {
                if abs(Int(a.bytes[i]) - Int(b.bytes[i])) > 16 || abs(Int(a.bytes[i + 1]) - Int(b.bytes[i + 1])) > 16 || abs(Int(a.bytes[i + 2]) - Int(b.bytes[i + 2])) > 16 {
                    diff += 1
                }
            }
        }
        let ratio = Double(diff) / Double(max(1, a.width * a.height))
        if ratio > Self.tolerance {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name + ".actual.png"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("\(name): \(Int(ratio * 100))% of the pixels differ from the snapshot (make snapshots to record anew)", file: file, line: line)
        }
    }

    struct Pixels {
        var width: Int, height: Int, bytes: [UInt8]
    }

    static func pixels(_ png: Data) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(width: w, height: h, bytes: bytes)
    }

    #if os(iOS)
    func render(_ content: AnyView, dark: Bool) async throws -> Data {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return try XCTUnwrap(image.pngData())
    }
    #else
    /// A window that always draws as the key window of an active app: whether the test host
    /// may activate depends on what else is on the screen, and a default button or a selected
    /// row looks different in an inactive window.
    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func render(_ content: AnyView, dark: Bool) async throws -> Data {
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        // at 1x: the pictures are for the eye and the diff, not for the shop window
        let w = Int(Self.size.width), h = Int(Self.size.height)
        let small = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(small.representation(using: .png, properties: [:]))
    }
    #endif
}
