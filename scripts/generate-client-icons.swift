#!/usr/bin/env swift
import AppKit
import Foundation

// Run from the repository root on macOS to rebuild platform icons from the mascot.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let client = root.appendingPathComponent("apps/client")
let source = client.appendingPathComponent("assets/brand/logo.png")
guard let logo = NSImage(contentsOf: source) else { fatalError("Cannot read mascot logo") }
let background = NSColor(srgbRed: 1, green: 243.0 / 255, blue: 245.0 / 255, alpha: 1)

func render(_ size: Int, to path: URL, mode: String) throws {
    let alpha = mode == "square" ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    guard let canvas = CGContext(data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)
        else { fatalError("Cannot create icon canvas") }
    let context = NSGraphicsContext(cgContext: canvas, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let edge = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: edge, height: edge)
    NSColor.clear.setFill()
    rect.fill(using: .copy)
    if mode == "square" {
        background.setFill()
        rect.fill()
    } else if mode == "mac" {
        background.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: edge * 0.06, dy: edge * 0.06),
            xRadius: edge * 0.19, yRadius: edge * 0.19).fill()
    }
    let fraction: CGFloat = mode == "foreground" ? 0.60 : mode == "mac" ? 0.77 : 0.86
    let side = edge * fraction
    let inset = (edge - side) / 2
    logo.draw(in: NSRect(x: inset, y: inset, width: side, height: side),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let bitmap = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: path)
}

for platform in ["ios", "macos"] {
    let folder = client.appendingPathComponent("\(platform)/Runner/Assets.xcassets/AppIcon.appiconset")
    let data = try Data(contentsOf: folder.appendingPathComponent("Contents.json"))
    let catalog = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var written = Set<String>()
    for item in catalog["images"] as! [[String: String]] {
        guard let file = item["filename"], written.insert(file).inserted else { continue }
        let points = Double(item["size"]!.split(separator: "x")[0])!
        let scale = Double(item["scale"]!.dropLast())!
        try render(Int((points * scale).rounded()), to: folder.appendingPathComponent(file),
            mode: platform == "ios" ? "square" : "mac")
    }
}
let res = client.appendingPathComponent("android/app/src/main/res")
for (density, scale) in [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0)] {
    let folder = res.appendingPathComponent("mipmap-\(density)")
    try render(Int(48 * scale), to: folder.appendingPathComponent("ic_launcher.png"), mode: "square")
    try render(Int(108 * scale), to: folder.appendingPathComponent("ic_launcher_foreground.png"), mode: "foreground")
}
try render(1024, to: client.appendingPathComponent("assets/brand/app-icon.png"), mode: "square")
print("Generated iOS, macOS, and Android icons.")
