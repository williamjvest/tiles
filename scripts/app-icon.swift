// Tiles app icon, Ink: the four camera tiles of the launch icon, drawn the way the app now draws
// itself. True black (with the faintest lift, so it doesn't read as a hole on a dark wallpaper), borderless tiles,
// each tile's caption a bar in its camera's color. Camera A is rolling, as the app's REC tile draws it: a red ring.
// The others show a readout (a value), the latency mark, and the shutter tile's ANG | SPD control.
//
// Usage, from the repo root: swift scripts/app-icon.swift [appiconset dir] [vector dir]
// Writes:
// - ios-1024.png: full bleed, no alpha. iOS applies its own mask.
// - mac-16 … mac-1024.png: the macOS rounded body on the 824/1024 grid with a soft shadow, drawn at each size
//   rather than downscaled.
// - The layered vector master, assets/app-icon/tiles-icon.svg, with one named layer per tile and the art split
//   into Body and Glyph.
// - assets/app-icon/layers/1-background, 2-tiles and 3-glyphs.svg: the same art as full-canvas layer files for
//   Icon Composer, Figma or Illustrator.
// The vector uses the same geometry as the PNGs, so they can't drift apart.
import AppKit

/// Lighter than the app's tiles (white 0.07): at icon size those vanish into the black.
let tileFill = NSColor(white: 0.14, alpha: 1)
let rec = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
let slots = [NSColor(red: 0.93, green: 0.28, blue: 0.26, alpha: 1), NSColor(red: 0.17, green: 0.50, blue: 0.98, alpha: 1),
             NSColor(red: 0.98, green: 0.80, blue: 0.10, alpha: 1), NSColor(red: 0.24, green: 0.80, blue: 0.34, alpha: 1)]
let caption = NSColor(white: 0.56, alpha: 1)
let valueWhite = NSColor(white: 0.96, alpha: 1)
let liftTop = NSColor(white: 0.075, alpha: 1), liftBottom = NSColor(white: 0.0, alpha: 1)

func circle(_ c: CGPoint, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

// MARK: - Geometry, shared by the PNGs and the vector

/// The four tiles: 70 % of the icon, 5 % apart. A, B over C, D.
func tiles(_ r: CGRect) -> [CGRect] {
    let s = r.width, gap = s * 0.05, size = (s * 0.70 - gap) / 2
    let origin = CGPoint(x: r.midX - size - gap / 2, y: r.midY - size - gap / 2)
    return (0..<4).map { i in
        CGRect(x: origin.x + CGFloat(i % 2) * (size + gap), y: origin.y + CGFloat(1 - i / 2) * (size + gap), width: size, height: size)
    }
}

func tileCorner(_ t: CGRect) -> CGFloat { t.width * 0.17 }

/// A tile's caption, as a bar in its camera's color where the app writes the caption.
func captionRect(_ t: CGRect, _ i: Int) -> CGRect {
    let u = t.width
    return CGRect(x: t.minX + u * 0.15, y: t.maxY - u * 0.25, width: u * (i == 0 ? 0.26 : 0.3), height: u * 0.075)
}

struct Ring { let center: CGPoint; let radius: CGFloat; let width: CGFloat }
func recRing(_ t: CGRect) -> Ring {
    Ring(center: CGPoint(x: t.midX, y: t.midY - t.width * 0.1), radius: t.width * 0.2, width: t.width * 0.06)
}

func valueRect(_ t: CGRect) -> CGRect {
    let u = t.width
    return CGRect(x: t.minX + u * 0.15, y: t.minY + u * 0.2, width: u * 0.62, height: u * 0.2)
}

/// The latency tile's broadcast mark, (( • )): its center, dot, arc radii and line width.
struct Broadcast { let center: CGPoint; let dot: CGFloat; let radii: [CGFloat]; let width: CGFloat }
func broadcast(_ t: CGRect) -> Broadcast {
    let u = t.width
    return Broadcast(center: CGPoint(x: t.midX, y: t.midY - u * 0.06), dot: u * 0.05, radii: [u * 0.14, u * 0.24], width: u * 0.05)
}
let arcs: [(CGFloat, CGFloat)] = [(-42, 42), (138, 222)]

/// ANG | SPD: the pill, its selected segment, and the two labels as bars.
struct Segmented { let pill: CGRect; let pillRadius: CGFloat; let seg: CGRect; let segRadius: CGFloat; let labels: [(CGRect, NSColor)]; let labelRadius: CGFloat }
func segmented(_ t: CGRect) -> Segmented {
    let u = t.width, w = u * 0.66, h = u * 0.24
    let pill = CGRect(x: t.midX - w / 2, y: t.midY - h / 2 - u * 0.06, width: w, height: h)
    let inset = h * 0.12, seg = CGRect(x: pill.minX + inset, y: pill.minY + inset, width: w / 2 - inset, height: h - inset * 2)
    let labels = [(seg.midX, valueWhite), (pill.maxX - w / 4, caption)].map { cx, color in
        (CGRect(x: cx - w * 0.12, y: pill.midY - h * 0.09, width: w * 0.24, height: h * 0.18), color)
    }
    return Segmented(pill: pill, pillRadius: h * 0.3, seg: seg, segRadius: h * 0.22, labels: labels, labelRadius: h * 0.09)
}

// MARK: - Raster

// The artwork, filling `r` edge to edge.
func artwork(_ r: CGRect) {
    NSGradient(starting: liftTop, ending: liftBottom)!.draw(in: r, angle: -90)
    for (i, t) in tiles(r).enumerated() {
        tileFill.setFill(); rounded(t, tileCorner(t)).fill()
        let c = captionRect(t, i)
        slots[i].setFill(); rounded(c, c.height / 2).fill()
        switch i {
        case 0:
            let ring = recRing(t), p = circle(ring.center, ring.radius)
            p.lineWidth = ring.width; rec.setStroke(); p.stroke()
        case 1:
            let v = valueRect(t)
            valueWhite.setFill(); rounded(v, t.width * 0.07).fill()
        case 2:
            let b = broadcast(t)
            valueWhite.setFill(); circle(b.center, b.dot).fill()
            for radius in b.radii {
                for (start, end) in arcs {
                    let p = NSBezierPath(); p.appendArc(withCenter: b.center, radius: radius, startAngle: start, endAngle: end)
                    p.lineWidth = b.width; p.lineCapStyle = .round; valueWhite.setStroke(); p.stroke()
                }
            }
        default:
            let s = segmented(t)
            NSColor(white: 1, alpha: 0.12).setFill(); rounded(s.pill, s.pillRadius).fill()
            NSColor(white: 1, alpha: 0.30).setFill(); rounded(s.seg, s.segRadius).fill()
            for (rect, color) in s.labels { color.setFill(); rounded(rect, s.labelRadius).fill() }
        }
    }
}

// Drawn straight into a CGContext. A 3-channel NSBitmapImageRep can't host an NSGraphicsContext (it renders solid
// black), so the no-alpha iOS icon uses an RGBX context instead: App Store Connect rejects a 1024 icon with alpha.
func png(_ px: Int, alpha: Bool, _ draw: (CGRect) -> Void) -> Data {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
    ctx.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

// macOS: the body sits on Apple's 824/1024 grid, with a soft drop shadow.
func macIcon(_ r: CGRect) {
    let k = r.width / 1024, body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k), radius = 185.4 * k
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35); shadow.shadowOffset = NSSize(width: 0, height: -10 * k); shadow.shadowBlurRadius = 20 * k
    shadow.set()
    NSColor.black.setFill(); rounded(body, radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    rounded(body, radius).addClip()
    artwork(body)
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Layered vector (SVG), the same geometry as artwork(_:) at 1024

func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB)!
    return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
                  Int((s.blueComponent * 255).rounded()))
}

func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }

struct VectorArt {
    let s: CGFloat = 1024
    func y(_ v: CGFloat) -> CGFloat { s - v }                      // AppKit is y-up, SVG is y-down
    func rect(_ r: CGRect, _ radius: CGFloat, _ attrs: String) -> String {
        "<rect x=\"\(f(r.minX))\" y=\"\(f(y(r.maxY)))\" width=\"\(f(r.width))\" height=\"\(f(r.height))\" rx=\"\(f(radius))\" \(attrs)/>"
    }
    func arc(_ c: CGPoint, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> String {
        func p(_ a: CGFloat) -> String { "\(f(c.x + r * cos(a * .pi / 180))) \(f(y(c.y + r * sin(a * .pi / 180))))" }
        return "M \(p(a0)) A \(f(r)) \(f(r)) 0 0 0 \(p(a1))"           // counter-clockwise on screen, like appendArc
    }

    // Every element, tagged with its tile (0-3, or -1 for the background) and its part.
    enum Part: String { case background = "Background", body = "Body", glyph = "Glyph" }
    func elements() -> [(tile: Int, part: Part, svg: String)] {
        var out: [(Int, Part, String)] = [(-1, .background, "<rect width=\"1024\" height=\"1024\" fill=\"url(#lift)\"/>")]
        for (i, t) in tiles(CGRect(x: 0, y: 0, width: s, height: s)).enumerated() {
            out.append((i, .body, rect(t, tileCorner(t), "fill=\"\(hex(tileFill))\"")))
            let c = captionRect(t, i)
            out.append((i, .glyph, rect(c, c.height / 2, "fill=\"\(hex(slots[i]))\"")))
            switch i {
            case 0:
                let ring = recRing(t)
                out.append((0, .glyph, "<circle cx=\"\(f(ring.center.x))\" cy=\"\(f(y(ring.center.y)))\" r=\"\(f(ring.radius))\" fill=\"none\" stroke=\"\(hex(rec))\" stroke-width=\"\(f(ring.width))\"/>"))
            case 1:
                out.append((1, .glyph, rect(valueRect(t), t.width * 0.07, "fill=\"\(hex(valueWhite))\"")))
            case 2:
                let b = broadcast(t)
                out.append((2, .glyph, "<circle cx=\"\(f(b.center.x))\" cy=\"\(f(y(b.center.y)))\" r=\"\(f(b.dot))\" fill=\"\(hex(valueWhite))\"/>"))
                let d = b.radii.flatMap { r in arcs.map { arc(b.center, r, $0.0, $0.1) } }.joined(separator: " ")
                out.append((2, .glyph, "<path d=\"\(d)\" fill=\"none\" stroke=\"\(hex(valueWhite))\" stroke-width=\"\(f(b.width))\" stroke-linecap=\"round\"/>"))
            default:
                let g = segmented(t)
                out.append((3, .glyph, rect(g.pill, g.pillRadius, "fill=\"#FFFFFF\" fill-opacity=\"0.12\"")))
                out.append((3, .glyph, rect(g.seg, g.segRadius, "fill=\"#FFFFFF\" fill-opacity=\"0.30\"")))
                for (r, color) in g.labels { out.append((3, .glyph, rect(r, g.labelRadius, "fill=\"\(hex(color))\""))) }
            }
        }
        return out
    }

    let defs = """
      <defs>
        <linearGradient id="lift" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="\(hex(liftTop))"/>
          <stop offset="1" stop-color="\(hex(liftBottom))"/>
        </linearGradient>
      </defs>
    """
    func document(_ title: String, _ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- \(title). Generated by scripts/app-icon.swift; edit that, not this. -->
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="1024" height="1024" viewBox="0 0 1024 1024">
        \(defs)
        \(body)
        </svg>

        """
    }
    func layer(_ id: String, _ label: String, _ content: [String], indent: String = "  ") -> String {
        "\(indent)<g id=\"\(id)\" inkscape:groupmode=\"layer\" inkscape:label=\"\(label)\">\n"
            + content.map { "\(indent)  \($0)" }.joined(separator: "\n") + "\n\(indent)</g>"
    }

    // The master: one layer per tile, each split into Body and Glyph sublayers.
    func master() -> String {
        let els = elements()
        let names = ["Tile A · REC (rolling)", "Tile B · Readout", "Tile C · Latency", "Tile D · ANG-SPD"]
        var layers = [layer("background", "Background", els.filter { $0.tile == -1 }.map(\.svg))]
        for i in 0..<4 {
            let tile = "tile-\(["a", "b", "c", "d"][i])"
            let sub = [Part.body, .glyph].map { part in
                layer("\(tile)-\(part.rawValue.lowercased())", part.rawValue, els.filter { $0.tile == i && $0.part == part }.map(\.svg), indent: "")
            }
            layers.append(layer(tile, names[i], sub.joined(separator: "\n").components(separatedBy: "\n")))
        }
        return document("Tiles app icon, layered master", layers.joined(separator: "\n"))
    }

    // Icon Composer style: each part on its own full-canvas file.
    func layerFile(_ part: Part) -> String {
        document("Tiles app icon, \(part.rawValue) layer",
                 layer(part.rawValue.lowercased(), part.rawValue, elements().filter { $0.part == part }.map(\.svg)))
    }
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                                : "App/CameraControl/Assets.xcassets/AppIcon.appiconset")
try png(1024, alpha: false, artwork).write(to: dir.appendingPathComponent("ios-1024.png"))
for px in [16, 32, 64, 128, 256, 512, 1024] {
    try png(px, alpha: true, macIcon).write(to: dir.appendingPathComponent("mac-\(px).png"))
}
print("wrote ios-1024.png and mac-16…1024.png to \(dir.path)")

let vectorDir = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "assets/app-icon")
let layersDir = vectorDir.appendingPathComponent("layers")
try FileManager.default.createDirectory(at: layersDir, withIntermediateDirectories: true)
let art = VectorArt()
try art.master().write(to: vectorDir.appendingPathComponent("tiles-icon.svg"), atomically: true, encoding: .utf8)
for (n, part) in [VectorArt.Part.background, .body, .glyph].enumerated() {
    let name = ["background", "tiles", "glyphs"][n]
    try art.layerFile(part).write(to: layersDir.appendingPathComponent("\(n + 1)-\(name).svg"), atomically: true, encoding: .utf8)
}
print("wrote tiles-icon.svg and layers/1-background, 2-tiles, 3-glyphs.svg to \(vectorDir.path)")
