import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code for the iPhone's camera, drawn as vector squares (one per module) so it stays sharp at any size.
struct QRWindow: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            QRCode(text: text)
                .frame(width: 280, height: 280)
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 312)
            Text("Point the iPhone\u{2019}s camera at it (Tailscale on).")
                .font(.callout)
        }
        .padding(24)
    }
}

private struct QRCode: View {
    let text: String

    /// The modules of the code: true is dark. Read from Core Image's generator at one pixel per module.
    private var modules: [[Bool]] {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let image = f.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return [] }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { y in (0..<w).map { x in pixels[y * w + x] < 128 } }
    }

    var body: some View {
        let grid = modules
        Canvas { context, size in
            guard let n = grid.first?.count, n > 0 else { return }
            let cell = min(size.width, size.height) / CGFloat(n)
            var path = Path()
            for (y, row) in grid.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    path.addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(.black))
        }
    }
}
