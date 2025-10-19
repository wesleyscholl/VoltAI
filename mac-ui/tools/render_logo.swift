#!/usr/bin/env swift
import Foundation
import AppKit
import SwiftUI

// Reuse your LogoView exactly (adjust if you changed it)
struct LogoView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 0.11, green: 0.56, blue: 0.8),
                                                                 Color(red: 0.18, green: 0.7, blue: 0.45)]),
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)

            Image(systemName: "bolt.fill")
                .foregroundColor(.white)
                .font(.system(size: 26, weight: .bold))
        }
    }
}

// Render function: returns an NSImage of given pixel size
func render<V: View>(_ view: V, size: CGSize) -> NSImage {
    // Scale the view by factor so that its built-in 56pt design scales to the target pixel size.
    let designBase: CGFloat = 56.0
    let scaleFactor = min(size.width, size.height) / designBase

    // Wrap view and scale it so the elements keep their relative proportions
    let scaledView = view
        .frame(width: designBase, height: designBase)
        .scaleEffect(scaleFactor, anchor: .center)

    let hosting = NSHostingView(rootView: scaledView)
    hosting.frame = CGRect(origin: .zero, size: size)

    // Ensure the view is laid out before snapshot
    hosting.layoutSubtreeIfNeeded()

    // Create a bitmap rep and ask the hosting view to draw into it
    let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) ??
              NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size.width),
                               pixelsHigh: Int(size.height),
                               bitsPerSample: 8,
                               samplesPerPixel: 4,
                               hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: NSColorSpaceName.calibratedRGB,
                               bytesPerRow: 0,
                               bitsPerPixel: 0)!

    rep.size = size // logical size in points for the rep
    hosting.cacheDisplay(in: hosting.bounds, to: rep)

        let image = NSImage(size: size)
        image.lockFocus()
        hosting.draw(hosting.bounds)
        image.unlockFocus()

        // Diagnostics: report presence of representations
        let repCount = image.representations.count
        fputs("[render_logo] image.size=\(image.size), representations=\(repCount)\n", stderr)
        if repCount > 0 {
            for (i, r) in image.representations.enumerated() {
                fputs("[render_logo] rep[\(i)] = \(type(of: r)), pixelsWide=\(r.pixelsWide), pixelsHigh=\(r.pixelsHigh)\n", stderr)
            }
        }
    image.addRepresentation(rep)
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    // Prefer any existing NSBitmapImageRep representation
    if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
       let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: url)
        return
    }

    // Fallback: convert TIFF -> NSBitmapImageRep -> PNG
    if let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: url)
        return
    }

    throw NSError(domain: "render_logo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to produce PNG data"])
}

// CLI: usage: render_logo.swift output.png [size]
// default size: 1024
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: render_logo.swift <output.png> [size]")
    exit(1)
}
let outPath = args[1]
let sizeVal: Int = (args.count >= 3) ? Int(args[2]) ?? 1024 : 1024
let size = CGSize(width: sizeVal, height: sizeVal)

// Ensure AppKit can run layout (no main event loop required).
autoreleasepool {
    let _ = NSApplication.shared // initialize AppKit
    let img = render(LogoView(), size: size)
    do {
            let outURL = URL(fileURLWithPath: outPath)
            let parent = outURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
                fputs("[render_logo] Created directory \(parent.path)\n", stderr)
            }
            try writePNG(img, to: outURL)
            print("Wrote \(outPath) \(Int(size.width))x\(Int(size.height))")
    } catch {
            fputs("[render_logo] Error writing PNG: \(error.localizedDescription)\n", stderr)
            if let nsErr = error as NSError? {
                fputs("[render_logo] NSError: domain=\(nsErr.domain) code=\(nsErr.code) userInfo=\(nsErr.userInfo)\n", stderr)
            }
            exit(2)
    }
}