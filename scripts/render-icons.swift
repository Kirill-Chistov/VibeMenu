import AppKit

// Regenerates VibeMenu's icon assets from the two shipped source artworks in
// App/IconSources:
//
//   - big_app_logo.png      → App icon  (AppIcon.appiconset)
//   - minilogo_for_bar.png  → Menu-bar template (MenuBarIcon.imageset)
//
// This replaces the earlier procedurally-drawn chevron/pulse art: the icons are now
// authored externally and this script only resamples them to the pixel sizes the
// asset catalog needs. No external dependencies (AppKit / CoreGraphics only).
//
// Usage:
//   swift scripts/render-icons.swift App/Assets.xcassets App/IconSources
//
//   arg1 = asset catalog dir (contains AppIcon.appiconset + MenuBarIcon.imageset)
//   arg2 = source dir (contains big_app_logo.png + minilogo_for_bar.png)

let args = CommandLine.arguments
guard args.count >= 3 else {
    fatalError("usage: render-icons.swift <assets.xcassets dir> <icon-sources dir>")
}
let outDir = args[1]
let srcDir = args[2]

let appIconDir = "\(outDir)/AppIcon.appiconset"
let menuDir = "\(outDir)/MenuBarIcon.imageset"
let appSource = "\(srcDir)/big_app_logo.png"
let menuSource = "\(srcDir)/minilogo_for_bar.png"

// --- Loading -----------------------------------------------------------------

/// Load a source image as a CGImage at its native pixel size.
func loadCGImage(_ path: String) -> CGImage {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("could not load image at \(path)")
    }
    return cg
}

func write(_ data: Data, _ path: String) {
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func makeContext(_ size: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

func pngData(_ ctx: CGContext) -> Data {
    let cg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])!
}

// --- App icon ----------------------------------------------------------------

// The source (big_app_logo.png) is already a finished, ready-to-ship app-icon tile: the
// rounded-squircle dark field, centered white glyph, margins, and drop shadow are all
// baked into the 1:1 artwork by the designer. It IS the tile. Earlier this script re-inset
// it (~8.6%) and re-clipped it to a rounded squircle, which shrank the already-complete
// artwork into a smaller tile floating in transparent margins — making the glyph look tiny
// and the icon look like a logo inside another tile. We now resample the source 1:1 to
// fill the whole canvas, so the app icon matches the provided artwork exactly (both are
// 1:1, no distortion). No inset, no rounded clipping, no added background/shadow/container.
func renderAppIcon(size: Int, source: CGImage) -> Data {
    let sz = CGFloat(size)
    let ctx = makeContext(size)
    ctx.clear(CGRect(x: 0, y: 0, width: sz, height: sz))
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: sz, height: sz))
    return pngData(ctx)
}

// --- Menu-bar template -------------------------------------------------------

// Fraction of the square canvas left as clear margin around the glyph on its widest
// side. Small so the wide "> - <" glyph reads large in the menu bar (the spec asks for
// it to not look too small) without touching the edges.
let TEMPLATE_MARGIN: CGFloat = 0.06

/// Opaque-alpha bounding box of a CGImage, in pixel coordinates (origin top-left).
func alphaBBox(_ cg: CGImage) -> CGRect {
    let w = cg.width, h = cg.height
    var raw = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = raw.withUnsafeMutableBytes { buf -> CGContext in
        CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: w * 4, space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            if raw[(y * w + x) * 4 + 3] > 12 {  // alpha threshold
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: w, height: h)  // fully transparent fallback
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Render the source glyph as a monochrome template: black pixels masked by the
/// source's alpha, auto-cropped to the glyph and scaled to fill the canvas (minus a
/// small margin). macOS ignores the color of a template image and tints it for
/// light/dark menu bars; the alpha shape is what matters, so there is no black square
/// — only the glyph silhouette.
func renderMenuTemplate(size: Int, source: CGImage, glyph: CGRect) -> Data {
    let sz = CGFloat(size)
    let ctx = makeContext(size)
    ctx.clear(CGRect(x: 0, y: 0, width: sz, height: sz))

    // Scale the (possibly non-square) glyph bbox to fit the target box, centered.
    let target = sz * (1 - 2 * TEMPLATE_MARGIN)
    let k = min(target / glyph.width, target / glyph.height)
    let drawW = glyph.width * k, drawH = glyph.height * k
    let dest = CGRect(x: (sz - drawW) / 2, y: (sz - drawH) / 2, width: drawW, height: drawH)

    // Crop the source to the glyph bbox. Source pixel coords are top-left origin;
    // CGImage.cropping uses the same, so no y-flip needed for the crop itself.
    guard let cropped = source.cropping(to: glyph) else {
        fatalError("failed to crop menu-bar source")
    }

    // Use the cropped alpha as a clip mask, then fill black through it. This yields a
    // clean black-on-transparent template regardless of the source's own color.
    ctx.saveGState()
    ctx.clip(to: dest, mask: cropped)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(dest)
    ctx.restoreGState()

    return pngData(ctx)
}

// --- Output ------------------------------------------------------------------

let appImage = loadCGImage(appSource)
print("app source: \(appImage.width)x\(appImage.height)")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(renderAppIcon(size: size, source: appImage), "\(appIconDir)/icon_\(size).png")
}

let menuImage = loadCGImage(menuSource)
let glyph = alphaBBox(menuImage)
print("menu source: \(menuImage.width)x\(menuImage.height), glyph bbox: "
      + "\(Int(glyph.origin.x)),\(Int(glyph.origin.y)) "
      + "\(Int(glyph.width))x\(Int(glyph.height))")
// Menu bar renders 1x/2x/3x → 18 / 36 / 54 px.
write(renderMenuTemplate(size: 18, source: menuImage, glyph: glyph), "\(menuDir)/menubar_18.png")
write(renderMenuTemplate(size: 36, source: menuImage, glyph: glyph), "\(menuDir)/menubar_36.png")
write(renderMenuTemplate(size: 54, source: menuImage, glyph: glyph), "\(menuDir)/menubar_54.png")
