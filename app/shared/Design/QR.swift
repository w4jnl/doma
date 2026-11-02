// A QR code for an invite or a guest link, drawn by CoreImage, on surface-sunk at radius-md as
// the design system has it. The link rides along in mono under it.
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum QR {
    /// The code as an image, crisp at any size.
    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

struct QRView: View {
    var text: String

    var body: some View {
        Group {
            if let cg = QR.image(text) {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(Tokens.space4)
            } else {
                Color.clear
            }
        }
        .background(Tokens.surfaceSunk, in: RoundedRectangle(cornerRadius: Tokens.radiusMD))
        .accessibilityLabel(Text("Invite code"))
    }
}
