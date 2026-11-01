// The camera that reads an invite's QR, on the phone and, through Continuity Camera or a built-in
// one, on the Mac. AVFoundation only; the code is handed back as text and the view does nothing
// else with the picture.
import AVFoundation
import SwiftUI

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

struct QRScanner: PlatformViewRepresentable {
    var found: @MainActor (String) -> Void

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        AVCaptureDevice.default(for: .video) != nil
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    #if os(iOS)
    func makeUIView(context: Context) -> PreviewView { make(context) }
    func updateUIView(_ view: PreviewView, context: Context) { context.coordinator.found = found }
    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) { coordinator.stop() }
    #else
    func makeNSView(context: Context) -> PreviewView { make(context) }
    func updateNSView(_ view: PreviewView, context: Context) { context.coordinator.found = found }
    static func dismantleNSView(_ view: PreviewView, coordinator: Coordinator) { coordinator.stop() }
    #endif

    private func make(_ context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(in: view)
        return view
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        var found: @MainActor (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "nl.w4j.doma.scan")

        init(found: @escaping @MainActor (String) -> Void) {
            self.found = found
        }

        func start(in view: PreviewView) {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            view.previewLayer = preview
            let session = self.session
            queue.async { [weak self] in
                guard let self else { return }
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    guard granted else { return }
                    guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
                    session.beginConfiguration()
                    if session.canAddInput(input) { session.addInput(input) }
                    let output = AVCaptureMetadataOutput()
                    if session.canAddOutput(output) {
                        session.addOutput(output)
                        output.setMetadataObjectsDelegate(self, queue: self.queue)
                        if output.availableMetadataObjectTypes.contains(.qr) {
                            output.metadataObjectTypes = [.qr]
                        }
                    }
                    session.commitConfiguration()
                    session.startRunning()
                }
            }
        }

        func stop() {
            let session = self.session
            queue.async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            let found = self.found
            Task { @MainActor in found(code) }
        }
    }
}

#if os(iOS)
final class PreviewView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let previewLayer {
                previewLayer.frame = bounds
                layer.addSublayer(previewLayer)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
#else
final class PreviewView: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
            oldValue?.removeFromSuperlayer()
            if let previewLayer {
                previewLayer.frame = bounds
                layer?.addSublayer(previewLayer)
            }
        }
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}
#endif
