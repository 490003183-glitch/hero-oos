import XCTest
import SwiftUI
import AppKit
@testable import HeroOOSNative

@MainActor final class PageBackgroundRenderingTests: XCTestCase {
    private func sourceImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor); context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        context.setFillColor(NSColor.systemOrange.cgColor); context.fillEllipse(in: CGRect(x: 250, y: 50, width: 300, height: 300))
        let image = try XCTUnwrap(context.makeImage())
        if let path = ProcessInfo.processInfo.environment["HERO_OOS_BACKGROUND_QA_FIXTURE"] {
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return NSImage(cgImage: image, size: NSSize(width: 800, height: 400))
    }
    private func render(_ image: NSImage?, fit: PageBackgroundFit = .fit, opacity: Double = 1, brightness: Double = 1) throws -> NSBitmapImageRep {
        let config = PageBackgroundConfiguration(assetName: UUID().uuidString + ".png", opacity: opacity, brightness: brightness, fit: fit)
        let renderer = ImageRenderer(content: PageBackgroundLayer(image: image, configuration: config)
            .frame(width: 400, height: 400).environment(\.colorScheme, .dark))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
    private func color(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }
    private func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        abs(lhs.redComponent - rhs.redComponent) + abs(lhs.greenComponent - rhs.greenComponent) + abs(lhs.blueComponent - rhs.blueComponent)
    }
    func testFitLetterboxesWithoutStretchingAndFillCropsWithoutDistortingCircle() throws {
        let image = try sourceImage(), base = try render(nil), fit = try render(image), fill = try render(image, fit: .fill)
        XCTAssertLessThan(try distance(color(fit, 200, 20), color(base, 200, 20)), 0.03)
        // 300px circle becomes 150px in fit and remains 300px in fill. Its
        // horizontal and vertical diameters stay equal in both modes.
        for (rendered, inside, outside) in [(fit, 65, 85), (fill, 140, 160)] {
            let center = try color(rendered, 200, 200)
            XCTAssertLessThan(try distance(color(rendered, 200 + inside, 200), center), 0.05)
            XCTAssertLessThan(try distance(color(rendered, 200, 200 + inside), center), 0.05)
            XCTAssertGreaterThan(try distance(color(rendered, 200 + outside, 200), center), 0.2)
            XCTAssertGreaterThan(try distance(color(rendered, 200, 200 + outside), center), 0.2)
        }
    }
    func testOpacityZeroRevealsBaseAndZeroBrightnessIsBlack() throws {
        let image = try sourceImage(), base = try render(nil), invisible = try render(image, opacity: 0), dark = try render(image, brightness: 0)
        XCTAssertLessThan(try distance(color(base, 200, 200), color(invisible, 200, 200)), 0.03)
        let black = try color(dark, 200, 200)
        XCTAssertLessThan(black.redComponent + black.greenComponent + black.blueComponent, 0.03)
    }
    func testNativeCanvasesRevealPageLayerWithoutChangingCanvasDocument() throws {
        let name = "HeroOOS.background-render." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let api = OOSAPI(base: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        let store = OOSStore(api: api, recoverDrafts: false)
        defer { store.stop() }
        let graph = TaskGraphModel(defaults: defaults); graph.showMiniMap = false; graph.reconcile([])
        let graphView = TaskGraphSurface(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        graphView.store = store; graphView.graph = graph
        let collage = CollageStore(api: api, recoverDrafts: false), original = collage.document
        let collageView = CollageSurface(frame: graphView.frame, viewportDefaults: defaults); collageView.model = collage
        for surface in [graphView as NSView, collageView as NSView] {
            for visible in [false, true] {
                graphView.pageBackgroundVisible = visible; collageView.pageBackgroundVisible = visible
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                NSColor.red.setFill(); surface.bounds.fill(); surface.draw(surface.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let pixel = try color(bitmap, 13, 100)
                if visible { XCTAssertLessThan(distance(pixel, .red), 0.03) }
                else { XCTAssertGreaterThan(distance(pixel, .red), 0.2) }
            }
        }
        XCTAssertEqual(collage.document, original); XCTAssertFalse(collage.dirty)
        XCTAssertTrue(store.pending.isEmpty)
    }
}
