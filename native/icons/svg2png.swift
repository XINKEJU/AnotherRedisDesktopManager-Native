import AppKit

// svg2png.swift <in.svg> <out.png> <px>
// AppKit's SVG reader is the only rasterizer guaranteed to exist on a plain
// macOS runner — no rsvg, inkscape, or brew install needed.
let a = CommandLine.arguments
guard a.count == 4, let px = Int(a[3]),
      let img = NSImage(contentsOfFile: a[1]) else { print("BAD_ARGS"); exit(1) }

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { print("CTX_FAILED"); exit(1) }
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.current = nil
guard let out = ctx.makeImage() else { print("IMAGE_FAILED"); exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("OK \(px)x\(px)")
