// Native icon packaging only: retain the generated artwork, apply the standard
// macOS rounded tile boundary, and emit the 1024px icon source. No image model or
// network access is involved in builds.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let sourceURL = directory.appendingPathComponent("ScholarsEyeArtwork.png")
let outputURL = directory.appendingPathComponent("ScholarsEyeAppIcon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let canvas = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                             bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not open the ScholarsEye artwork or create the icon canvas.")
}
canvas.interpolationQuality = .high
let tile = CGRect(x: 64, y: 64, width: 896, height: 896)
canvas.addPath(CGPath(roundedRect: tile, cornerWidth: 200, cornerHeight: 200, transform: nil))
canvas.clip()
canvas.setFillColor(CGColor(gray: 1, alpha: 1))
canvas.fill(tile)
canvas.draw(artwork, in: tile)
guard let icon = canvas.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create the icon PNG.")
}
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write the icon PNG.") }
print(outputURL.path)
