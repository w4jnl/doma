// The signed client against a stub transport: the three headers, a signature the public key
// verifies over the server's signing string, the problem documents, and the invite link forms.
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import XCTest
@testable import Doma
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

final class ClientTests: XCTestCase {
    override func setUp() {
        StubProtocol.handler = nil
    }

    func client(credential: String? = "C1") -> SyncClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return SyncClient(baseURL: URL(string: "https://doma.example")!, key: DeviceKey.make(), credentialID: credential,
                          session: URLSession(configuration: config), now: { Date(timeIntervalSince1970: 1_700_000_000.5) })
    }

    func testSyncRequestIsSigned() async throws {
        let c = client()
        let seen = Captured()
        StubProtocol.handler = { req in
            seen.request = req
            seen.body = req.httpBody ?? req.httpBodyStream.map { StubProtocol.read($0) } ?? Data()
            return (200, Data(#"{"households":[{"id":"H1","accepted":["e1"],"rejected":[],"events":[],"next":7,"snapshot":null}]}"#.utf8), [:])
        }
        let resp = try await c.sync(SyncRequest(households: [.init(id: "H1", since: 0, events: [.object(["id": .string("e1")])])]))
        XCTAssertEqual(resp.households.first?.next, 7)
        XCTAssertEqual(resp.households.first?.accepted, ["e1"])
        let req = try XCTUnwrap(seen.request)
        XCTAssertEqual(req.value(forHTTPHeaderField: SyncClient.headerCredential), "C1")
        XCTAssertEqual(req.value(forHTTPHeaderField: SyncClient.headerTimestamp), "1700000000500")
        let sig = try XCTUnwrap(req.value(forHTTPHeaderField: SyncClient.headerSignature).flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(sig.count, 64)
        let message = SyncClient.signingString(method: "POST", path: "/sync/v1", timestamp: "1700000000500", body: seen.body)
        XCTAssertTrue(c.key.publicKey!.isValidSignature(sig, for: message))
        XCTAssertFalse(c.key.publicKey!.isValidSignature(sig, for: message + Data([1])))
        XCTAssertEqual(String(decoding: seen.body, as: UTF8.self), #"{"households":[{"events":[{"id":"e1"}],"id":"H1","since":0}]}"#)
    }

    func testSigningStringMatchesTheServer() {
        // method, path, timestamp and the hex SHA-256 of the body, newline separated
        let s = SyncClient.signingString(method: "GET", path: "/api/v1/me", timestamp: "1", body: Data())
        XCTAssertEqual(String(decoding: s, as: UTF8.self), "GET\n/api/v1/me\n1\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAcceptIsUnsignedAndCarriesTheKey() async throws {
        let c = client(credential: nil)
        let seen = Captured()
        StubProtocol.handler = { req in
            seen.request = req
            seen.body = req.httpBody ?? req.httpBodyStream.map { StubProtocol.read($0) } ?? Data()
            return (201, Data(#"{"server":"https://doma.example","person_id":"P1","credential_id":"C9","household":{"id":"H1","name":"De Vries","timezone":"Europe/Amsterdam","staleness_days":14},"role":"member"}"#.utf8), [:])
        }
        let acc = try await c.accept(token: "tok", displayName: "Sam", label: "Sam's iPhone", platform: "ios")
        XCTAssertEqual(acc.credentialID, "C9")
        XCTAssertEqual(acc.household.name, "De Vries")
        XCTAssertNil(seen.request?.value(forHTTPHeaderField: SyncClient.headerSignature))
        XCTAssertEqual(seen.request?.url?.path, "/i/tok")
        let body = try JSONValue(data: seen.body)
        XCTAssertEqual(body["public_key"]?.stringValue, c.key.publicKeyString)
        XCTAssertTrue(c.key.publicKeyString.hasPrefix("ed25519:"))
        XCTAssertEqual(Data(base64Encoded: String(c.key.publicKeyString.dropFirst(8)))?.count, 32)
        XCTAssertEqual(body["platform"]?.stringValue, "ios")
    }

    func testProblemsBecomeErrors() async {
        let c = client()
        StubProtocol.handler = { _ in (409, Data(#"{"status":409,"title":"Conflict","detail":"That invite was used already. Ask for a new one."}"#.utf8), [:]) }
        do {
            _ = try await c.accept(token: "tok", displayName: "x", label: "y", platform: "ios")
            XCTFail("no error")
        } catch ClientError.problem(let p) {
            XCTAssertEqual(p.status, 409)
            XCTAssertEqual(p.message, "That invite was used already. Ask for a new one.")
        } catch {
            XCTFail("\(error)")
        }
        StubProtocol.handler = { _ in (401, Data(#"{"status":401,"title":"Unauthorized"}"#.utf8), [:]) }
        do {
            _ = try await c.sync(SyncRequest(households: []))
            XCTFail("no error")
        } catch ClientError.unauthorized {
        } catch {
            XCTFail("\(error)")
        }
        StubProtocol.handler = { _ in (429, Data(), ["Retry-After": "3"]) }
        do {
            _ = try await c.sync(SyncRequest(households: []))
            XCTFail("no error")
        } catch ClientError.rateLimited(let wait) {
            XCTAssertEqual(wait, 3)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMeCarriesTheHouseholdWithAndWithoutStaleness() throws {
        // a current doma says the household's time zone and staleness; an older one only its name
        let full = Data("""
        {"person":{"id":"P1","display_name":"Jaro"},"credentials":[],
         "memberships":[{"household_id":"H1","household_name":"Family","timezone":"Europe/Amsterdam","staleness_days":60,"role":"owner"}]}
        """.utf8)
        let me = try JSONDecoder().decode(MeDocument.self, from: full)
        XCTAssertEqual(me.memberships.first?.timezone, "Europe/Amsterdam")
        XCTAssertEqual(me.memberships.first?.stalenessDays, 60)
        let old = Data("""
        {"person":{"id":"P1","display_name":"Jaro"},"credentials":[],
         "memberships":[{"household_id":"H1","household_name":"Family","role":"owner"}]}
        """.utf8)
        let older = try JSONDecoder().decode(MeDocument.self, from: old)
        XCTAssertNil(older.memberships.first?.timezone)
        XCTAssertNil(older.memberships.first?.stalenessDays)
    }

    func testInviteLinks() {
        XCTAssertEqual(InviteLink("https://doma.example/i/abcdefghijklmnopqrstuvwxyz0123456789-_AB"), InviteLink(server: URL(string: "https://doma.example")!, token: "abcdefghijklmnopqrstuvwxyz0123456789-_AB"))
        XCTAssertEqual(InviteLink("http://localhost:8086/i/abcdefghijklmnopqrstuv")?.server, URL(string: "http://localhost:8086"))
        XCTAssertEqual(InviteLink("doma://invite#abcdefghijklmnopqrstuv"), InviteLink(server: nil, token: "abcdefghijklmnopqrstuv"))
        XCTAssertEqual(InviteLink("  abcdefghijklmnopqrstuv \n"), InviteLink(server: nil, token: "abcdefghijklmnopqrstuv"))
        XCTAssertNil(InviteLink("https://doma.example/g/abcdefghijklmnopqrstuv"))
        XCTAssertNil(InviteLink("short"))
        XCTAssertNil(InviteLink("https://doma.example/i/has space in it 1234567"))
        XCTAssertNil(InviteLink(""))
    }

    func testQRRoundTripsThroughVision() throws {
        let text = "http://127.0.0.1:8097/i/abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
        let cg = try XCTUnwrap(QR.image(text))
        #if canImport(UIKit)
        let png = try XCTUnwrap(UIImage(cgImage: cg).pngData())
        #else
        let rep = NSBitmapImageRep(cgImage: cg)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        #endif
        XCTAssertEqual(UITestHooks.decodeQR(png: png), text)
        // and the picture the UI test makes, a CIImage written as PNG
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let png2 = try XCTUnwrap(CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        XCTAssertEqual(UITestHooks.decodeQR(png: png2), text)
    }

    func testDeviceKeyRoundTripsThroughTheKeychain() throws {
        DeviceKey.forget()
        XCTAssertNil(DeviceKey.load())
        let k = try DeviceKey.loadOrMake()
        XCTAssertEqual(DeviceKey.load(), k)
        XCTAssertEqual(try DeviceKey.loadOrMake(), k)
        let sig = try k.sign(Data("hello".utf8))
        XCTAssertTrue(k.publicKey!.isValidSignature(sig, for: Data("hello".utf8)))
        DeviceKey.forget()
        XCTAssertNil(DeviceKey.load())
    }
}

/// What a stub call saw.
final class Captured: @unchecked Sendable {
    var request: URLRequest?
    var body = Data()
}

/// A URLProtocol that answers from a handler.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, data, headers) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

