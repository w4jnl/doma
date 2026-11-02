// The hooks the UI tests and the snapshot tests use, all behind DOMA_UITEST=1 in the launch
// environment or a flag the tests set: a fresh store in memory, an invite joined at launch, a
// QR handed to Scan as a picture (decoded with Vision, as the camera's output would be), sync
// held back until doma://uitest/online opens. Nothing here runs for a person.
import CoreImage
import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum UITestHooks {
    nonisolated(unsafe) private static let env = ProcessInfo.processInfo.environment

    static var enabled: Bool { env["DOMA_UITEST"] == "1" }

    /// An invite URL the session accepts at launch, with this name.
    static var joinURL: String? { env["DOMA_UITEST_JOIN"] }
    static var joinName: String { env["DOMA_UITEST_NAME"] ?? "Jaro" }

    /// A QR code as a PNG in base64, for Scan to read in place of the camera.
    static var qrPNG: Data? { env["DOMA_UITEST_QR_PNG"].flatMap { Data(base64Encoded: $0) } }

    /// Sync held back, so an add lands in the outbox and the offline badge shows.
    nonisolated(unsafe) static var blockSync = false

    /// How long after the launch's join the network stays away, then comes back by itself: a UI
    /// test cannot reach into the app once it runs.
    static var offlineSeconds: Double { env["DOMA_UITEST_OFFLINE_SECONDS"].flatMap(Double.init) ?? 0 }

    /// The camera shown as absent, so Scan renders its field.
    nonisolated(unsafe) static var noCamera = env["DOMA_UITEST_NO_CAMERA"] == "1"

    /// The one QR code in a picture, as text: Vision where it runs, CoreImage's detector where
    /// it does not (the simulator).
    static func decodeQR(png: Data) -> String? {
        #if canImport(UIKit)
        guard let cg = UIImage(data: png)?.cgImage else { return nil }
        #else
        guard let image = NSImage(data: png), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([request])
        if let text = request.results?.compactMap(\.payloadStringValue).first {
            return text
        }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}
