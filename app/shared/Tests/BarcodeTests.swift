// Every barcode the app draws is read back by Vision as the same value in the same format:
// the one check that matters for a code a till has to scan.
import AVFoundation
import Vision
import XCTest
@testable import Doma

final class BarcodeTests: XCTestCase {
    /// Start and stop letters a Codabar reader may or may not report.
    private func bareCodabar(_ s: String) -> String {
        var t = s
        if let f = t.first, "ABCD".contains(f) { t.removeFirst() }
        if let l = t.last, "ABCD".contains(l) { t.removeLast() }
        return t
    }

    func testEveryFormatRoundTripsThroughVision() throws {
        let cases: [(format: String, value: String, read: String, as: String)] = [
            ("ean13", "262000000000", "2620000000008", "ean13"),
            ("ean8", "9638507", "96385074", "ean8"),
            ("upca", "03600029145", "0036000291452", "ean13"),
            ("upce", "0123456", "01234565", "upce"),
            ("itf14", "1540014128876", "15400141288763", "itf14"),
            ("code39", "LIB-42", "LIB-42", "code39"),
            ("code93", "LIB-42", "LIB-42", "code93"),
            ("codabar", "40156", "A40156B", "codabar"),
            ("code128", "LIB-42 x", "LIB-42 x", "code128"),
            ("qr", "https://doma.example/c/1", "https://doma.example/c/1", "qr"),
            ("aztec", "AZ 12345", "AZ 12345", "aztec"),
            ("pdf417", "PDF 12345", "PDF 12345", "pdf417"),
            ("datamatrix", "DM-42", "DM-42", "datamatrix"),
            ("datamatrix", "1234567890123456789012345678901234567890", "1234567890123456789012345678901234567890", "datamatrix"),
        ]
        // the simulator's Vision reads no barcode at all; the Mac's and a phone's do
        if let probe = Barcode.image("probe", format: "qr"), Barcode.read(probe) == nil {
            #if targetEnvironment(simulator)
            throw XCTSkip("Vision reads no barcode in this simulator; make mac-test covers the round trip")
            #else
            XCTFail("Vision reads nothing here, not even a QR")
            #endif
        }
        for c in cases {
            let normalized = try XCTUnwrap(Barcode.normalized(c.value, format: c.format), "\(c.format) refuses \(c.value)")
            let image = try XCTUnwrap(Barcode.image(c.value, format: c.format), "\(c.format) draws nothing")
            guard let read = Barcode.read(image) else {
                XCTFail("\(c.format) \(c.value): Vision read nothing")
                continue
            }
            if c.format == "codabar" {
                XCTAssertEqual(bareCodabar(read.value), bareCodabar(c.read), "codabar value")
                XCTAssertEqual(normalized, "A40156B")
            } else {
                XCTAssertEqual(read.value, c.read, "\(c.format) value")
            }
            XCTAssertEqual(read.format, c.as, "\(c.format) read as")
            if c.format == "upca" {
                XCTAssertEqual(normalized, "036000291452", "the check digit is added")
            }
        }
    }

    func testNormalizedRefusesWhatATillWouldRefuse() {
        XCTAssertNil(Barcode.normalized("2620000000006", format: "ean13"), "a wrong check digit")
        XCTAssertEqual(Barcode.normalized("2620000000008", format: "ean13"), "2620000000008", "a right one")
        XCTAssertNil(Barcode.normalized("26200000000", format: "ean13"), "too short")
        XCTAssertNil(Barcode.normalized("26200000000AB", format: "ean13"), "letters")
        XCTAssertEqual(Barcode.normalized("lib-42", format: "code39"), "LIB-42", "lowercase is uppercased")
        XCTAssertNil(Barcode.normalized("A4B5C", format: "codabar"), "a stop letter in the middle")
        XCTAssertEqual(Barcode.normalized("12345678", format: "upce"), nil, "a wrong UPC-E check digit")
        XCTAssertEqual(Barcode.normalized("01234565", format: "upce"), "01234565")
        XCTAssertNil(Barcode.normalized("", format: "qr"))
        XCTAssertNil(Barcode.normalized("x", format: "nope"))
    }

    func testGuessAndCleaning() {
        XCTAssertEqual(CardActions.guessFormat(for: "2620000000008"), "ean13")
        XCTAssertEqual(CardActions.guessFormat(for: "9638 5074"), "ean8")
        XCTAssertEqual(CardActions.guessFormat(for: "036000291452"), "upca")
        XCTAssertEqual(CardActions.guessFormat(for: "15400141288763"), "itf14")
        XCTAssertEqual(CardActions.guessFormat(for: "LIB-42"), "code128")
        XCTAssertEqual(CardActions.guessFormat(for: ""), "code128")
        XCTAssertEqual(CardActions.cleaned(" 2620 0000 00008 "), "2620000000008")
        XCTAssertEqual(CardActions.cleaned("LIB-42 "), "LIB-42", "letters keep their dashes")
    }

    func testTheCameraAndVisionNameTheFormats() {
        XCTAssertEqual(Barcode.format(of: AVMetadataObject.ObjectType.ean13, value: "2620000000008"), "ean13")
        XCTAssertEqual(Barcode.format(of: AVMetadataObject.ObjectType.interleaved2of5, value: "15400141288763"), "itf14")
        XCTAssertNil(Barcode.format(of: AVMetadataObject.ObjectType.interleaved2of5, value: "1234"), "an interleaved code of another length is not drawn")
        XCTAssertEqual(Barcode.format(of: VNBarcodeSymbology.code39Checksum, value: "X"), "code39")
        XCTAssertNil(Barcode.format(of: VNBarcodeSymbology.microQR, value: "X"))
        XCTAssertEqual(Barcode.formats.count, Card.formats.count, "the picker names every format the schema allows")
        XCTAssertEqual(Set(Barcode.formats.map(\.id)), Set(Card.formats))
    }
}
