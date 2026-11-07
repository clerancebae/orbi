// Draws the Orbi app icon (1024×1024 PNG). Usage: swift scripts/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }
func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }

// macOS icon grid: 824×824 body centred, corner radius ~185, soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
ctx.addPath(shape); ctx.setFillColor(c(20, 18, 48)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// night-sky background
ctx.drawLinearGradient(grad([c(44, 32, 110), c(14, 14, 40)], [0, 1]),
                       start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// faint glow behind the orb
let center = CGPoint(x: 512, y: 512)
ctx.drawRadialGradient(grad([c(255, 150, 80, 0.45), c(255, 120, 80, 0)], [0, 1]),
                       startCenter: center, startRadius: 0, endCenter: center, endRadius: 400, options: [])
// tiny stars
let stars: [(CGFloat, CGFloat, CGFloat)] = [(230, 780, 5), (790, 820, 4), (300, 260, 3.5), (820, 300, 5), (700, 700, 3), (180, 520, 3)]
for (x, y, r) in stars { ctx.setFillColor(c(255, 255, 255, 0.7)); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2*r, height: 2*r)) }

// orbit: tilted ellipse; back half drawn before the orb, front half after.
let tilt = -0.42 as CGFloat
let rx: CGFloat = 330, ry: CGFloat = 112
func orbitPath(from a0: CGFloat, to a1: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt).scaledBy(x: 1, y: ry / rx)
    p.addArc(center: .zero, radius: rx, startAngle: a0, endAngle: a1, clockwise: false, transform: t)
    return p
}
func strokeOrbit(_ p: CGPath, alpha: CGFloat) {
    ctx.saveGState()
    ctx.addPath(p); ctx.setLineWidth(22); ctx.setLineCap(.butt)
    ctx.setStrokeColor(c(255, 255, 255, alpha)); ctx.strokePath()
    ctx.restoreGState()
}
strokeOrbit(orbitPath(from: 0, to: .pi), alpha: 0.35)            // back

// the orb (sun / day)
let R: CGFloat = 200
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - R, y: center.y - R, width: 2*R, height: 2*R)); ctx.clip()
ctx.drawRadialGradient(grad([c(255, 236, 160), c(255, 170, 70), c(240, 90, 80)], [0, 0.55, 1]),
                       startCenter: CGPoint(x: center.x - 70, y: center.y + 80), startRadius: 10,
                       endCenter: center, endRadius: R, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

strokeOrbit(orbitPath(from: .pi, to: 2 * .pi), alpha: 0.95)      // front

// moon on the front of the orbit
let a: CGFloat = 1.72 * .pi
let mt = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
let m = CGPoint(x: rx * cos(a), y: ry * sin(a)).applying(mt)
let mr: CGFloat = 50
ctx.setShadow(offset: .zero, blur: 30, color: c(120, 220, 255, 0.9))
ctx.addEllipse(in: CGRect(x: m.x - mr, y: m.y - mr, width: 2*mr, height: 2*mr))
ctx.setFillColor(c(140, 225, 255)); ctx.fillPath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
