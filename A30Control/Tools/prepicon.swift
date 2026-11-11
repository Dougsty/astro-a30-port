// Builds the app icon and the menu bar glyph from Assets/icon.png (Doug's 1254×1254 artwork,
// opaque black around a rounded tile).
//   prepicon SRC OUT_DIR  →  OUT_DIR/icon-1024.png   (tile clipped to the macOS icon shape)
//                            OUT_DIR/menubar.png, menubar@2x.png  (template mask: "a" + star)
//                            OUT_DIR/logo.png  (white "a" + red star, transparent, for the window header)
import AppKit

let src = NSBitmapImageRep(data: NSImage(contentsOfFile: CommandLine.arguments[1])!.tiffRepresentation!)!
let outDir = CommandLine.arguments[2]
let W = CGFloat(src.pixelsWide), H = CGFloat(src.pixelsHigh)
let srcImage = NSImage(size: NSSize(width: W, height: H)); srcImage.addRepresentation(src)

func write(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
func canvas(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

// 1. App icon: tile region (fractions of the source, y measured from the top), scaled into the
//    824 px body of a 1024 canvas and clipped to a rounded rect so the black surround is dropped.
// just inside the tile's glass border (tile spans ~0.08–0.92 × 0.076–0.885)
let tile = NSRect(x: 0.10 * W, y: (1 - 0.875) * H, width: 0.80 * W, height: 0.785 * H)   // AppKit y-up
let icon = canvas(1024, 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: icon)
NSGraphicsContext.current!.imageInterpolation = .high
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).addClip()
srcImage.draw(in: body, from: tile, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
write(icon, "icon-1024.png")

// 2. Menu bar template: white glyph (bright, unsaturated) + red star → black with alpha.
let region = (x0: Int(0.22 * W), y0: Int(0.14 * H), x1: Int(0.875 * W), y1: Int(0.67 * H))   // y from top
let rw = region.x1 - region.x0, rh = region.y1 - region.y0
let mask = canvas(rw, rh)
let logo = canvas(rw, rh)
for y in 0..<rh { for x in 0..<rw {
    guard let c = src.colorAt(x: region.x0 + x, y: region.y0 + y)?.usingColorSpace(.deviceRGB) else { continue }
    let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
    let redness = c.redComponent - max(c.greenComponent, c.blueComponent)
    let a = max(max(0, min(1, (lo - 0.55) / 0.3)), max(0, min(1, (redness - 0.3) / 0.3)))
    let px = mask.bitmapData! + y * mask.bytesPerRow + x * 4
    px[0] = 0; px[1] = 0; px[2] = 0; px[3] = UInt8(a * 255)
    // logo keeps the source color (premultiplied), so the star stays red
    let lp = logo.bitmapData! + y * logo.bytesPerRow + x * 4
    lp[0] = UInt8(c.redComponent * a * 255); lp[1] = UInt8(c.greenComponent * a * 255)
    lp[2] = UInt8(c.blueComponent * a * 255); lp[3] = UInt8(a * 255)
}}
write(logo, "logo.png")
let maskImage = NSImage(size: NSSize(width: rw, height: rh)); maskImage.addRepresentation(mask)
for (scale, name) in [(1, "menubar.png"), (2, "menubar@2x.png")] {
    let h = 16 * scale, w = Int((CGFloat(rw) / CGFloat(rh) * CGFloat(h)).rounded())
    let r = canvas(w, h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
    NSGraphicsContext.current!.imageInterpolation = .high
    maskImage.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    write(r, name)
}
