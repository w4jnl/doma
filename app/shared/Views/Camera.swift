// The camera that takes a spot's picture, on the phone and, through Continuity Camera or a
// built-in one, on the Mac. AVFoundation only: a preview and one still per tap, handed back as
// the bytes the camera made; nothing else is kept. Without a camera (the simulator, a test) the
// shutter makes a plain picture with the spot's name on it, so the flow still runs.
import AVFoundation
import CoreGraphics
import CoreText
import SwiftUI

/// What the screen holds to ask the camera for a picture.
@MainActor @Observable
final class Shutter {
    fileprivate var take: (@MainActor (@escaping @MainActor (Data?) -> Void) -> Void)?
    private(set) var ready = false

    static var hasCamera: Bool { QRScanner.isAvailable }

    /// One picture, as the camera's bytes, or a stand-in when there is no camera.
    func capture(label: String, _ done: @escaping @MainActor (Data?) -> Void) {
        if let take {
            take(done)
        } else {
            done(Self.standIn(label: label))
        }
    }

    fileprivate func attach(_ take: @escaping @MainActor (@escaping @MainActor (Data?) -> Void) -> Void) {
        self.take = take
        ready = true
    }

    fileprivate func detach() {
        take = nil
        ready = false
    }

    /// A plain picture: the brand's ground with the spot's name, 1200 by 900.
    nonisolated static func standIn(label: String) -> Data? {
        let w = 1200, h = 900
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.13, green: 0.16, blue: 0.17, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.37, green: 0.77, blue: 0.48, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 2 - 160, y: h / 2 - 60, width: 320, height: 320))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: CGColor(gray: 0.95, alpha: 1)]))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (CGFloat(w) - bounds.width) / 2, y: 120)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { return nil }
        return Pictures.encode(image)?.data
    }
}

struct CameraView: PlatformViewRepresentable {
    var shutter: Shutter

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(iOS)
    func makeUIView(context: Context) -> PreviewView { make(context) }
    func updateUIView(_ view: PreviewView, context: Context) {}
    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) { coordinator.stop() }
    #else
    func makeNSView(context: Context) -> PreviewView { make(context) }
    func updateNSView(_ view: PreviewView, context: Context) {}
    static func dismantleNSView(_ view: PreviewView, coordinator: Coordinator) { coordinator.stop() }
    #endif

    private func make(_ context: Context) -> PreviewView {
        let view = PreviewView()
        let coordinator = context.coordinator
        coordinator.start(in: view)
        let shutter = self.shutter
        shutter.attach { done in coordinator.capture(done) }
        coordinator.onStop = { Task { @MainActor in shutter.detach() } }
        return view
    }

    final class Coordinator: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let output = AVCapturePhotoOutput()
        private let queue = DispatchQueue(label: "nl.w4j.doma.camera")
        private var pending: (@MainActor (Data?) -> Void)?
        var onStop: (() -> Void)?

        func start(in view: PreviewView) {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            view.previewLayer = preview
            let session = self.session
            let output = self.output
            queue.async {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    guard granted, let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
                    session.beginConfiguration()
                    session.sessionPreset = .photo
                    if session.canAddInput(input) { session.addInput(input) }
                    if session.canAddOutput(output) { session.addOutput(output) }
                    session.commitConfiguration()
                    session.startRunning()
                }
            }
        }

        func stop() {
            let session = self.session
            queue.async { session.stopRunning() }
            onStop?()
        }

        /// One still; the delegate hands its bytes back on the main actor.
        @MainActor func capture(_ done: @escaping @MainActor (Data?) -> Void) {
            pending = done
            let output = self.output
            queue.async { [self] in
                guard session.isRunning else {
                    Task { @MainActor in done(nil) }
                    return
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                output.capturePhoto(with: settings, delegate: self)
            }
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            let data = error == nil ? photo.fileDataRepresentation() : nil
            let done = pending
            pending = nil
            Task { @MainActor in done?(data) }
        }
    }
}
