// Draws the Pocket Muse app icon (the app's breathing orb on night blue) as a 1024 px opaque PNG.
//   swift ios/make_icon.swift ios/PocketMuse/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)
let center = CGPoint(x: s / 2, y: s / 2)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func radial(_ colors: [CGColor], _ stops: [CGFloat], at c: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius,
                           options: [.drawsAfterEndLocation])
}

// Night-blue background, lighter toward the middle.
radial([rgb(0.10, 0.12, 0.26), rgb(0.03, 0.03, 0.08)], [0, 1], at: center, radius: s * 0.75)

// Soft halo.
radial([rgb(0.45, 0.55, 1.0, 0.55), rgb(0.55, 0.35, 0.95, 0.18), rgb(0.3, 0.2, 0.8, 0)], [0, 0.55, 1],
       at: center, radius: s * 0.42)

// The orb: bright core offset up-left, violet rim.
ctx.saveGState()
let orbR = s * 0.25
ctx.addEllipse(in: CGRect(x: center.x - orbR, y: center.y - orbR, width: orbR * 2, height: orbR * 2))
ctx.clip()
radial([rgb(0.86, 0.94, 1.0), rgb(0.47, 0.64, 1.0), rgb(0.50, 0.33, 0.92)], [0, 0.5, 1],
       at: CGPoint(x: center.x - orbR * 0.28, y: center.y + orbR * 0.32), radius: orbR * 1.45)
ctx.restoreGState()

// Two sparkles, up-right: Muse thinking ahead.
func sparkle(_ c: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
    let p = CGMutablePath()
    let w = r * 0.22
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - w, y: c.y + w))
    ctx.addPath(p)
    ctx.setFillColor(rgb(1, 0.95, 0.85, alpha))
    ctx.fillPath()
}
sparkle(CGPoint(x: center.x + s * 0.27, y: center.y + s * 0.25), s * 0.075, 0.95)
sparkle(CGPoint(x: center.x + s * 0.36, y: center.y + s * 0.12), s * 0.035, 0.75)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
