// A card's barcode, drawn by the app and never fetched (docs/design.md, "Cards"): Core Image
// for Code 128, QR, Aztec and PDF417; doma's own encoders for the one-dimensional codes the
// shops use, EAN-13, EAN-8, UPC-A, UPC-E, Code 39, Code 93, ITF-14 and Codabar, and for Data
// Matrix. Every encoder is tested by drawing a value and reading it back with Vision. The same
// file maps what the camera and Vision read to the format names the event schema spells.
import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

enum Barcode {
    /// The formats with the words a person sees for them.
    static let formats: [(id: String, name: String)] = [
        ("ean13", "EAN-13"), ("ean8", "EAN-8"), ("upca", "UPC-A"), ("upce", "UPC-E"), ("code128", "Code 128"), ("code39", "Code 39"),
        ("code93", "Code 93"), ("itf14", "ITF-14"), ("codabar", "Codabar"), ("qr", "QR"), ("aztec", "Aztec"), ("pdf417", "PDF417"),
        ("datamatrix", "Data Matrix"),
    ]

    static func name(of format: String) -> String {
        formats.first { $0.id == format }?.name ?? format
    }

    /// Whether the format is a row of bars (true) or a square (false).
    static func isLinear(_ format: String) -> Bool {
        !["qr", "aztec", "pdf417", "datamatrix"].contains(format)
    }

    /// The value as the barcode carries it, or nil when it cannot be drawn in the format: a
    /// missing check digit is added, a wrong one refused, letters a digits-only code lacks
    /// refused.
    static func normalized(_ value: String, format: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        switch format {
        case "ean13":
            return withCheck(v, length: 13, weights: [1, 3])
        case "ean8":
            return withCheck(v, length: 8, weights: [3, 1])
        case "upca":
            return withCheck(v, length: 12, weights: [3, 1])
        case "upce":
            return UPCE.normalized(v)
        case "itf14":
            return withCheck(v, length: 14, weights: [3, 1])
        case "code39":
            let u = v.uppercased()
            return u.allSatisfy({ Code39.patterns[$0] != nil && $0 != "*" }) ? u : nil
        case "code93":
            let u = v.uppercased()
            return u.allSatisfy({ Code93.values[$0] != nil }) ? u : nil
        case "codabar":
            return Codabar.normalized(v)
        case "code128":
            return v.unicodeScalars.allSatisfy({ $0.value < 128 }) ? v : nil
        case "qr", "aztec", "pdf417", "datamatrix":
            return v
        default:
            return nil
        }
    }

    /// A digits-only code of a fixed length with its check digit: given without it, it is
    /// added; given with it, it must agree.
    private static func withCheck(_ v: String, length: Int, weights: [Int]) -> String? {
        guard v.allSatisfy(\.isNumber) else { return nil }
        if v.count == length - 1 {
            return v + String(checkDigit(v, weights: weights))
        }
        guard v.count == length, let last = v.last?.wholeNumberValue else { return nil }
        return checkDigit(String(v.dropLast()), weights: weights) == last ? v : nil
    }

    /// The modulo 10 check digit of digits weighted from the left by the cycle given.
    static func checkDigit(_ digits: String, weights: [Int]) -> Int {
        var sum = 0
        for (i, ch) in digits.enumerated() {
            sum += (ch.wholeNumberValue ?? 0) * weights[i % weights.count]
        }
        return (10 - sum % 10) % 10
    }

    // MARK: Drawing

    /// The code as an image, crisp at any size; nil when the value cannot be drawn.
    static func image(_ value: String, format: String) -> CGImage? {
        guard let v = normalized(value, format: format) else { return nil }
        switch format {
        case "code128":
            let f = CIFilter.code128BarcodeGenerator()
            f.message = Data(v.utf8)
            f.quietSpace = 10
            return render(f.outputImage, scale: 6)
        case "qr":
            let f = CIFilter.qrCodeGenerator()
            f.message = Data(v.utf8)
            f.correctionLevel = "M"
            return render(f.outputImage, scale: 10)
        case "aztec":
            let f = CIFilter.aztecCodeGenerator()
            f.message = Data(v.utf8)
            f.correctionLevel = 23
            return render(f.outputImage, scale: 10)
        case "pdf417":
            let f = CIFilter.pdf417BarcodeGenerator()
            f.message = Data(v.utf8)
            return render(f.outputImage, scale: 6)
        case "datamatrix":
            guard let grid = DataMatrix.symbol(for: Array(v.utf8)) else { return nil }
            return draw(grid: grid, scale: 10, quiet: 4)
        default:
            guard let bars = modules(v, format: format) else { return nil }
            return draw(bars: bars, scale: 6, quiet: 11, height: 180)
        }
    }

    private static func render(_ out: CIImage?, scale: CGFloat) -> CGImage? {
        guard let out else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    /// The bars of a one-dimensional code as modules, true for a bar.
    static func modules(_ value: String, format: String) -> [Bool]? {
        guard let v = normalized(value, format: format) else { return nil }
        switch format {
        case "ean13": return EAN.ean13(v)
        case "ean8": return EAN.ean8(v)
        case "upca": return EAN.ean13("0" + v)
        case "upce": return UPCE.modules(v)
        case "code39": return Code39.modules(v)
        case "code93": return Code93.modules(v)
        case "itf14": return ITF.modules(v)
        case "codabar": return Codabar.modules(v)
        default: return nil
        }
    }

    private static func draw(bars: [Bool], scale: Int, quiet: Int, height: Int) -> CGImage? {
        let width = (bars.count + 2 * quiet) * scale
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        for (i, bar) in bars.enumerated() where bar {
            ctx.fill(CGRect(x: (quiet + i) * scale, y: 0, width: scale, height: height))
        }
        return ctx.makeImage()
    }

    private static func draw(grid: [[Bool]], scale: Int, quiet: Int) -> CGImage? {
        let n = grid.count
        let side = (n + 2 * quiet) * scale
        guard let ctx = context(width: side, height: side) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        for (r, row) in grid.enumerated() {
            for (c, dark) in row.enumerated() where dark {
                // CoreGraphics draws from the bottom; the symbol's first row is at the top
                ctx.fill(CGRect(x: (quiet + c) * scale, y: (quiet + n - 1 - r) * scale, width: scale, height: scale))
            }
        }
        return ctx.makeImage()
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    // MARK: Reading

    /// What the camera listens for when a card is added.
    static let cameraTypes: [AVMetadataObject.ObjectType] = [
        .ean13, .ean8, .upce, .code39, .code93, .code128, .itf14, .interleaved2of5, .codabar, .qr, .aztec, .pdf417, .dataMatrix,
    ]

    /// The format of a code the camera read, by the type it names and the value.
    static func format(of type: AVMetadataObject.ObjectType, value: String) -> String? {
        switch type {
        case .ean13: return "ean13"
        case .ean8: return "ean8"
        case .upce: return "upce"
        case .code39, .code39Mod43: return "code39"
        case .code93: return "code93"
        case .code128: return "code128"
        case .itf14: return "itf14"
        case .interleaved2of5: return value.count == 14 ? "itf14" : nil
        case .codabar: return "codabar"
        case .qr: return "qr"
        case .aztec: return "aztec"
        case .pdf417: return "pdf417"
        case .dataMatrix: return "datamatrix"
        default: return nil
        }
    }

    /// The format of a code Vision read in a picture.
    static func format(of symbology: VNBarcodeSymbology, value: String) -> String? {
        switch symbology {
        case .ean13: return "ean13"
        case .ean8: return "ean8"
        case .upce: return "upce"
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: return "code39"
        case .code93, .code93i: return "code93"
        case .code128: return "code128"
        case .itf14: return "itf14"
        case .i2of5, .i2of5Checksum: return value.count == 14 ? "itf14" : nil
        case .codabar: return "codabar"
        case .qr: return "qr"
        case .aztec: return "aztec"
        case .pdf417: return "pdf417"
        case .dataMatrix: return "datamatrix"
        default: return nil
        }
    }

    /// The first barcode in a picture that doma can draw: a screenshot of a card in another
    /// wallet, pasted, or a test's own drawing.
    static func read(_ image: CGImage) -> (value: String, format: String)? {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        for o in request.results ?? [] {
            guard let value = o.payloadStringValue, !value.isEmpty, let f = format(of: o.symbology, value: value) else { continue }
            return (value, f)
        }
        return nil
    }
}

// MARK: - EAN and UPC

/// EAN-13, EAN-8 and UPC-A: the L, G and R digit patterns between the guard bars.
enum EAN {
    static let left = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
    static var right: [String] { left.map { String($0.map { $0 == "0" ? "1" : "0" }) } }
    static var even: [String] { right.map { String($0.reversed()) } }
    /// The parity of the six left digits of an EAN-13, by its first digit.
    static let parity13 = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]

    static func bits(_ s: String) -> [Bool] { s.map { $0 == "1" } }

    static func ean13(_ v: String) -> [Bool]? {
        let d = v.compactMap(\.wholeNumberValue)
        guard d.count == 13 else { return nil }
        var out = bits("101")
        let parity = Array(parity13[d[0]])
        for i in 1...6 {
            out += bits(parity[i - 1] == "L" ? left[d[i]] : even[d[i]])
        }
        out += bits("01010")
        for i in 7...12 {
            out += bits(right[d[i]])
        }
        out += bits("101")
        return out
    }

    static func ean8(_ v: String) -> [Bool]? {
        let d = v.compactMap(\.wholeNumberValue)
        guard d.count == 8 else { return nil }
        var out = bits("101")
        for i in 0...3 { out += bits(left[d[i]]) }
        out += bits("01010")
        for i in 4...7 { out += bits(right[d[i]]) }
        out += bits("101")
        return out
    }
}

/// UPC-E: eight digits, the number system, six digits and the check digit of the UPC-A the
/// code stands for, which decides the parity of the six.
enum UPCE {
    /// Parity for number system 0 by check digit; E is an even (G) pattern, O an odd (L) one.
    static let parity0 = ["EEEOOO", "EEOEOO", "EEOOEO", "EEOOOE", "EOEEOO", "EOOEEO", "EOOOEE", "EOEOEO", "EOEOOE", "EOOEOE"]

    /// The UPC-A digits (without check) a UPC-E's number system and six digits stand for.
    static func expanded(system: Int, _ d: [Int]) -> [Int] {
        let (d1, d2, d3, d4, d5, d6) = (d[0], d[1], d[2], d[3], d[4], d[5])
        switch d6 {
        case 0, 1, 2: return [system, d1, d2, d6, 0, 0, 0, 0, d3, d4, d5]
        case 3: return [system, d1, d2, d3, 0, 0, 0, 0, 0, d4, d5]
        case 4: return [system, d1, d2, d3, d4, 0, 0, 0, 0, 0, d5]
        default: return [system, d1, d2, d3, d4, d5, 0, 0, 0, 0, d6]
        }
    }

    /// Six, seven or eight digits in; the eight the code carries out, or nil.
    static func normalized(_ v: String) -> String? {
        guard v.allSatisfy(\.isNumber) else { return nil }
        var d = v.compactMap(\.wholeNumberValue)
        if d.count == 6 { d.insert(0, at: 0) }
        guard d.count == 7 || d.count == 8, d[0] == 0 || d[0] == 1 else { return nil }
        let check = Barcode.checkDigit(expanded(system: d[0], Array(d[1...6])).map(String.init).joined(), weights: [3, 1])
        if d.count == 7 { return (d + [check]).map(String.init).joined() }
        return d[7] == check ? v : nil
    }

    static func modules(_ v: String) -> [Bool]? {
        let d = v.compactMap(\.wholeNumberValue)
        guard d.count == 8 else { return nil }
        var parity = Array(parity0[d[7]])
        if d[0] == 1 { parity = parity.map { $0 == "E" ? "O" : "E" } }
        var out = EAN.bits("101")
        for i in 0..<6 {
            out += EAN.bits(parity[i] == "O" ? EAN.left[d[i + 1]] : EAN.even[d[i + 1]])
        }
        out += EAN.bits("010101")
        return out
    }
}

// MARK: - Code 39, Code 93, ITF, Codabar

/// Wide and narrow elements, bars and spaces in turn starting with a bar; a narrow space
/// between characters.
enum Widths {
    static func modules(_ patterns: [String], wide: Int, gap: Bool = true) -> [Bool] {
        var out: [Bool] = []
        for (n, p) in patterns.enumerated() {
            if n > 0, gap { out.append(false) }
            for (i, ch) in p.enumerated() {
                let w = ch == "W" ? wide : 1
                out += Array(repeating: i % 2 == 0, count: w)
            }
        }
        return out
    }
}

enum Code39 {
    static let patterns: [Character: String] = [
        "0": "NNNWWNWNN", "1": "WNNWNNNNW", "2": "NNWWNNNNW", "3": "WNWWNNNNN", "4": "NNNWWNNNW", "5": "WNNWWNNNN", "6": "NNWWWNNNN",
        "7": "NNNWNNWNW", "8": "WNNWNNWNN", "9": "NNWWNNWNN", "A": "WNNNNWNNW", "B": "NNWNNWNNW", "C": "WNWNNWNNN", "D": "NNNNWWNNW",
        "E": "WNNNWWNNN", "F": "NNWNWWNNN", "G": "NNNNNWWNW", "H": "WNNNNWWNN", "I": "NNWNNWWNN", "J": "NNNNWWWNN", "K": "WNNNNNNWW",
        "L": "NNWNNNNWW", "M": "WNWNNNNWN", "N": "NNNNWNNWW", "O": "WNNNWNNWN", "P": "NNWNWNNWN", "Q": "NNNNNNWWW", "R": "WNNNNNWWN",
        "S": "NNWNNNWWN", "T": "NNNNWNWWN", "U": "WWNNNNNNW", "V": "NWWNNNNNW", "W": "WWWNNNNNN", "X": "NWNNWNNNW", "Y": "WWNNWNNNN",
        "Z": "NWWNWNNNN", "-": "NWNNNNWNW", ".": "WWNNNNWNN", " ": "NWWNNNWNN", "$": "NWNWNWNNN", "/": "NWNWNNNWN", "+": "NWNNNWNWN",
        "%": "NNNWNWNWN", "*": "NWNNWNWNN",
    ]

    static func modules(_ v: String) -> [Bool]? {
        let chars = Array("*" + v + "*")
        var ps: [String] = []
        for c in chars {
            guard let p = patterns[c] else { return nil }
            ps.append(p)
        }
        return Widths.modules(ps, wide: 3)
    }
}

enum Code93 {
    static let patterns = [
        "100010100", "101001000", "101000100", "101000010", "100101000", "100100100", "100100010", "101010000", "100010010", "100001010",
        "110101000", "110100100", "110100010", "110010100", "110010010", "110001010", "101101000", "101100100", "101100010", "100110100",
        "100011010", "101011000", "101001100", "101000110", "100101100", "100010110", "110110100", "110110010", "110101100", "110100110",
        "110010110", "110011010", "101101100", "101100110", "100110110", "100111010", "100101110", "111010100", "111010010", "111001010",
        "101101110", "101110110", "110101110", "100100110", "111011010", "111010110", "100110010",
    ]
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%")
    static let values: [Character: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
    static let start = "101011110"

    static func check(_ vals: [Int], max: Int) -> Int {
        var sum = 0
        var w = 1
        for v in vals.reversed() {
            sum += v * w
            w = w == max ? 1 : w + 1
        }
        return sum % 47
    }

    static func modules(_ v: String) -> [Bool]? {
        var vals: [Int] = []
        for c in v {
            guard let n = values[c] else { return nil }
            vals.append(n)
        }
        let c = check(vals, max: 20)
        let k = check(vals + [c], max: 15)
        var s = start
        for n in vals + [c, k] { s += patterns[n] }
        s += start + "1"
        return s.map { $0 == "1" }
    }
}

/// ITF-14, interleaved 2 of 5: digits in pairs, the first as bars and the second as spaces.
enum ITF {
    static let patterns = ["NNWWN", "WNNNW", "NWNNW", "WWNNN", "NNWNW", "WNWNN", "NWWNN", "NNNWW", "WNNWN", "NWNWN"]

    static func modules(_ v: String) -> [Bool]? {
        let d = v.compactMap(\.wholeNumberValue)
        guard d.count == 14 else { return nil }
        var out: [Bool] = [true, false, true, false]
        for i in stride(from: 0, to: 14, by: 2) {
            let bars = Array(patterns[d[i]]), spaces = Array(patterns[d[i + 1]])
            for j in 0..<5 {
                out += Array(repeating: true, count: bars[j] == "W" ? 3 : 1)
                out += Array(repeating: false, count: spaces[j] == "W" ? 3 : 1)
            }
        }
        out += [true, true, true, false, true]
        return out
    }
}

enum Codabar {
    static let patterns: [Character: String] = [
        "0": "NNNNNWW", "1": "NNNNWWN", "2": "NNNWNNW", "3": "WWNNNNN", "4": "NNWNNWN", "5": "WNNNNWN", "6": "NWNNNNW", "7": "NWNNWNN",
        "8": "NWWNNNN", "9": "WNNWNNN", "-": "NNNWWNN", "$": "NNWWNNN", ":": "WNNNWNW", "/": "WNWNNNW", ".": "WNWNWNN", "+": "NNWNWNW",
        "A": "NNWWNWN", "B": "NWNWNNW", "C": "NNNWNWW", "D": "NNNWWWN",
    ]

    /// With its start and stop letters: a bare number is wrapped in A and B.
    static func normalized(_ v: String) -> String? {
        let u = v.uppercased()
        guard u.allSatisfy({ patterns[$0] != nil }) else { return nil }
        let isStop: (Character) -> Bool = { "ABCD".contains($0) }
        if u.count >= 3, let f = u.first, let l = u.last, isStop(f), isStop(l), !u.dropFirst().dropLast().contains(where: isStop) {
            return u
        }
        guard !u.contains(where: isStop) else { return nil }
        return "A" + u + "B"
    }

    static func modules(_ v: String) -> [Bool]? {
        var ps: [String] = []
        for c in v {
            guard let p = patterns[c] else { return nil }
            ps.append(p)
        }
        return Widths.modules(ps, wide: 3)
    }
}

// MARK: - Data Matrix

/// Data Matrix ECC 200, square symbols up to 48 by 48: ASCII encodation, Reed-Solomon over
/// GF(256) with the polynomial 301, the standard placement, the finder pattern around each
/// region.
enum DataMatrix {
    struct Size {
        var symbol: Int
        /// The data region's side without its finder, and how many regions per side.
        var region: Int
        var regions: Int
        var data: Int
        var ec: Int
        var mapping: Int { region * regions }
    }

    static let sizes = [
        Size(symbol: 10, region: 8, regions: 1, data: 3, ec: 5), Size(symbol: 12, region: 10, regions: 1, data: 5, ec: 7),
        Size(symbol: 14, region: 12, regions: 1, data: 8, ec: 10), Size(symbol: 16, region: 14, regions: 1, data: 12, ec: 12),
        Size(symbol: 18, region: 16, regions: 1, data: 18, ec: 14), Size(symbol: 20, region: 18, regions: 1, data: 22, ec: 18),
        Size(symbol: 22, region: 20, regions: 1, data: 30, ec: 20), Size(symbol: 24, region: 22, regions: 1, data: 36, ec: 24),
        Size(symbol: 26, region: 24, regions: 1, data: 44, ec: 28), Size(symbol: 32, region: 14, regions: 2, data: 62, ec: 36),
        Size(symbol: 36, region: 16, regions: 2, data: 86, ec: 42), Size(symbol: 40, region: 18, regions: 2, data: 114, ec: 48),
        Size(symbol: 44, region: 20, regions: 2, data: 144, ec: 56), Size(symbol: 48, region: 22, regions: 2, data: 174, ec: 68),
    ]

    /// The bytes as ASCII encodation codewords: digit pairs as one, the rest as the byte plus one.
    static func codewords(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if i + 1 < bytes.count, (48...57).contains(b), (48...57).contains(bytes[i + 1]) {
                out.append(UInt8(130 + Int(b - 48) * 10 + Int(bytes[i + 1] - 48)))
                i += 2
            } else if b >= 128 {
                out.append(235)
                out.append(b - 127)
                i += 1
            } else {
                out.append(b + 1)
                i += 1
            }
        }
        return out
    }

    /// The pad codewords after the data: 129, then the randomised 253-state pads.
    static func padded(_ words: [UInt8], to n: Int) -> [UInt8] {
        var out = words
        if out.count < n { out.append(129) }
        while out.count < n {
            let p = (149 * (out.count + 1)) % 253 + 1 + 129
            out.append(UInt8(p > 254 ? p - 254 : p))
        }
        return out
    }

    // GF(256) with the polynomial x^8 + x^5 + x^3 + x^2 + 1 (301)
    static let (exp, log): ([UInt8], [Int]) = {
        var exp = [UInt8](repeating: 0, count: 256)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x >= 256 { x ^= 301 }
        }
        exp[255] = exp[0]
        return (exp, log)
    }()

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[(log[Int(a)] + log[Int(b)]) % 255]
    }

    /// The error correction codewords of the data for a generator with roots α^1 to α^n.
    static func errorCorrection(_ data: [UInt8], count n: Int) -> [UInt8] {
        var g: [UInt8] = [1]
        for i in 1...n {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, c) in g.enumerated() {
                next[j] ^= mul(c, exp[i])
                next[j + 1] ^= c
            }
            g = next
        }
        // g is lowest degree first; divide x^n * data by g
        var reg = [UInt8](repeating: 0, count: n)
        for d in data {
            let k = d ^ reg[n - 1]
            for i in stride(from: n - 1, to: 0, by: -1) {
                reg[i] = reg[i - 1] ^ mul(g[i], k)
            }
            reg[0] = mul(g[0], k)
        }
        return reg.reversed()
    }

    /// The symbol's modules, finder included; nil when the message is too long for 48 by 48.
    static func symbol(for bytes: [UInt8]) -> [[Bool]]? {
        let words = codewords(bytes)
        guard let size = sizes.first(where: { $0.data >= words.count }) else { return nil }
        let data = padded(words, to: size.data)
        let all = data + errorCorrection(data, count: size.ec)
        let map = place(all, rows: size.mapping, cols: size.mapping)
        // the finder around each region: a solid left column and bottom row, alternating top
        // row and right column
        let n = size.symbol
        var out = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
        let side = size.region + 2
        for rr in 0..<size.regions {
            for rc in 0..<size.regions {
                let top = rr * side, left = rc * side
                for r in 0..<side {
                    for c in 0..<side {
                        let dark: Bool
                        if c == 0 || r == side - 1 {
                            dark = true
                        } else if r == 0 {
                            dark = c % 2 == 0
                        } else if c == side - 1 {
                            dark = r % 2 == 1
                        } else {
                            dark = map[rr * size.region + r - 1][rc * size.region + c - 1]
                        }
                        out[top + r][left + c] = dark
                    }
                }
            }
        }
        return out
    }

    /// The ECC 200 placement of codewords in the mapping matrix.
    static func place(_ words: [UInt8], rows nrow: Int, cols ncol: Int) -> [[Bool]] {
        var matrix = [[Bool]](repeating: [Bool](repeating: false, count: ncol), count: nrow)
        var used = [[Bool]](repeating: [Bool](repeating: false, count: ncol), count: nrow)
        func module(_ r: Int, _ c: Int, _ chr: Int, _ bit: Int) {
            var row = r, col = c
            if row < 0 {
                row += nrow
                col += 4 - ((nrow + 4) % 8)
            }
            if col < 0 {
                col += ncol
                row += 4 - ((ncol + 4) % 8)
            }
            let word = chr < words.count ? words[chr] : 0
            matrix[row][col] = (word >> (8 - bit)) & 1 == 1
            used[row][col] = true
        }
        func utah(_ row: Int, _ col: Int, _ chr: Int) {
            module(row - 2, col - 2, chr, 1)
            module(row - 2, col - 1, chr, 2)
            module(row - 1, col - 2, chr, 3)
            module(row - 1, col - 1, chr, 4)
            module(row - 1, col, chr, 5)
            module(row, col - 2, chr, 6)
            module(row, col - 1, chr, 7)
            module(row, col, chr, 8)
        }
        func corner1(_ chr: Int) {
            module(nrow - 1, 0, chr, 1)
            module(nrow - 1, 1, chr, 2)
            module(nrow - 1, 2, chr, 3)
            module(0, ncol - 2, chr, 4)
            module(0, ncol - 1, chr, 5)
            module(1, ncol - 1, chr, 6)
            module(2, ncol - 1, chr, 7)
            module(3, ncol - 1, chr, 8)
        }
        func corner2(_ chr: Int) {
            module(nrow - 3, 0, chr, 1)
            module(nrow - 2, 0, chr, 2)
            module(nrow - 1, 0, chr, 3)
            module(0, ncol - 4, chr, 4)
            module(0, ncol - 3, chr, 5)
            module(0, ncol - 2, chr, 6)
            module(0, ncol - 1, chr, 7)
            module(1, ncol - 1, chr, 8)
        }
        func corner3(_ chr: Int) {
            module(nrow - 3, 0, chr, 1)
            module(nrow - 2, 0, chr, 2)
            module(nrow - 1, 0, chr, 3)
            module(0, ncol - 2, chr, 4)
            module(0, ncol - 1, chr, 5)
            module(1, ncol - 1, chr, 6)
            module(2, ncol - 1, chr, 7)
            module(3, ncol - 1, chr, 8)
        }
        func corner4(_ chr: Int) {
            module(nrow - 1, 0, chr, 1)
            module(nrow - 1, ncol - 1, chr, 2)
            module(0, ncol - 3, chr, 3)
            module(0, ncol - 2, chr, 4)
            module(0, ncol - 1, chr, 5)
            module(1, ncol - 3, chr, 6)
            module(1, ncol - 2, chr, 7)
            module(1, ncol - 1, chr, 8)
        }
        var row = 4, col = 0, chr = 0
        repeat {
            if row == nrow, col == 0 {
                corner1(chr)
                chr += 1
            }
            if row == nrow - 2, col == 0, ncol % 4 != 0 {
                corner2(chr)
                chr += 1
            }
            if row == nrow - 2, col == 0, ncol % 8 == 4 {
                corner3(chr)
                chr += 1
            }
            if row == nrow + 4, col == 2, ncol % 8 == 0 {
                corner4(chr)
                chr += 1
            }
            repeat {
                if row < nrow, col >= 0, !used[row][col] {
                    utah(row, col, chr)
                    chr += 1
                }
                row -= 2
                col += 2
            } while row >= 0 && col < ncol
            row += 1
            col += 3
            repeat {
                if row >= 0, col < ncol, !used[row][col] {
                    utah(row, col, chr)
                    chr += 1
                }
                row += 2
                col -= 2
            } while row < nrow && col >= 0
            row += 3
            col += 1
        } while row < nrow || col < ncol
        if !used[nrow - 1][ncol - 1] {
            matrix[nrow - 1][ncol - 1] = true
            matrix[nrow - 2][ncol - 2] = true
        }
        return matrix
    }
}
