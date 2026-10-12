import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// The Subject Card's picture: a Subject Quick Look can draw fills the Card
/// edge to edge, rounded with the glass; one it cannot keeps the icon layout.
///
/// Rendered offscreen and read back by pixel — the content layer only; see
/// `render(_:size:)`.
@MainActor
struct SubjectCardPictureTests {

    private static let scale: CGFloat = 2

    // MARK: - Fixtures

    /// A solid red 4:3 image — wider than the square Card, so aspect-fill has
    /// to crop its sides and cover top to bottom.
    private static func redImage(width: Int = 400, height: Int = 300) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func writeRedPNG() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-card-picture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(
            NSBitmapImageRep(cgImage: Self.redImage()).representation(using: .png, properties: [:])
        )
        let url = directory.appendingPathComponent("photo.png")
        try data.write(to: url)
        return url
    }

    private func fileSubject(_ url: URL) -> Subject {
        Subject(
            displayName: url.lastPathComponent,
            path: url.path,
            url: url,
            icon: NSWorkspace.shared.icon(forFile: url.path),
            kind: .file(contentType: .png),
            thumbnailURL: url
        )
    }

    /// What the Card draws on its first frame is the last thumbnail made for
    /// its request, so a test makes it first — at the Card's size, covering
    /// it, which is also what proves the Card asks for that.
    private func warmThumbnail(for url: URL) async throws {
        let request = Thumbnails.Request(url: url, side: Style.cardSide, scale: Self.scale, fills: true)
        _ = try #require(await Thumbnails.shared.thumbnail(for: request))
    }

    private struct Card: View {
        let coordinator: CommandCoordinator
        @Namespace private var glass

        var body: some View {
            SubjectCardView(coordinator: coordinator, glassNamespace: glass)
                .frame(width: PanelLayout.cardWidth, height: PanelLayout.cardHeight)
        }
    }

    // MARK: - Reading pixels

    /// RGBA8, top-left origin, in points.
    private struct Pixels: CustomStringConvertible {
        var description: String { "\(width)×\(height)px" }

        let width: Int
        let height: Int
        let scale: CGFloat
        let bytes: [Double]

        init(_ image: CGImage, scale: CGFloat) {
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            self.scale = scale
            var raw = [UInt8](repeating: 0, count: width * height * 4)
            raw.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            bytes = raw.map(Double.init)
        }

        func rgba(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
            let px = Int(x * scale), py = Int(y * scale)
            let i = (py * width + px) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }

        func at(_ x: CGFloat, _ y: CGFloat) -> String {
            let p = rgba(x, y)
            return "(\(x), \(y)) = rgba(\(Int(p.r)), \(Int(p.g)), \(Int(p.b)), \(Int(p.a)))"
        }

        func isRed(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let p = rgba(x, y)
            // Pure red, through whatever colour space the render lands in.
            return p.a > 240 && p.r > 200 && p.g < 90 && p.b < 90
        }

        func isClear(_ x: CGFloat, _ y: CGFloat) -> Bool {
            rgba(x, y).a < 10
        }
    }

    /// Drawn by an `NSHostingView` in a window that is never shown, and read
    /// back with `cacheDisplay`. That captures the Card's **content** layer —
    /// the picture, the icon, the caption, the chips — and not the glass
    /// material, which the window server draws; `ImageRenderer` draws nothing
    /// at all for a view carrying `.glassEffect` in the test host. The content
    /// layer is the one under test here, and without the glass it is
    /// deterministic, so one render is enough.
    ///
    /// The Card asks for its thumbnail at `displayScale`, so the test fixes it
    /// at the scale the cache was warmed at, whatever screen the host is on.
    private func render<V: View>(_ view: V, size: CGFloat) throws -> Pixels {
        let host = NSHostingView(rootView: view.environment(\.displayScale, Self.scale))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try #require(rep.cgImage)
        return Pixels(image, scale: CGFloat(image.width) / size)
    }

    // MARK: - The picture alone

    /// Aspect-fill: a 4:3 picture in a square reaches all four edges, its sides
    /// cropped, and its corners are cut at the Card's radius.
    @Test func thePictureFillsItsFrameAndRoundsItsCorners() throws {
        let side = Style.cardSide
        let image = NSImage(cgImage: Self.redImage(), size: NSSize(width: 200, height: 150))
        let pixels = try render(CardPicture(image: image, captioned: false), size: side)

        for (x, y) in [(side / 2, 0.5), (side / 2, side - 0.5), (0.5, side / 2), (side - 0.5, side / 2)] {
            #expect(pixels.isRed(x, y), "edge at \(x), \(y)")
        }
        #expect(pixels.isRed(side / 2, side / 2))
        // The corners are cut: a 20pt corner leaves the very corner empty and
        // the point 8pt in along the diagonal filled.
        for (x, y) in [(0.5, 0.5), (side - 0.5, 0.5), (0.5, side - 0.5), (side - 0.5, side - 0.5)] {
            #expect(pixels.isClear(x, y), "corner at \(x), \(y)")
        }
        #expect(pixels.isRed(Style.cardRadius * 0.4, Style.cardRadius * 0.4))
    }

    /// The picture's corner is the glass's corner: the same radius, because it
    /// is laid out in the frame the glass is drawn in.
    @Test func thePictureIsConcentricWithTheGlass() {
        #expect(Style.pictureShape.cornerSize == Style.cardShape.cornerSize)
        #expect(Style.cardSide == PanelLayout.cardWidth - 2 * Style.cardInset)
        #expect(PanelLayout.cardWidth == PanelLayout.cardHeight)
    }

    // MARK: - On the Card

    /// The focused Card: the picture reaches the glass's edges, 6pt inside the
    /// cell, and nothing is drawn past them.
    @Test func aFocusedCardsPictureReachesTheGlassEdges() async throws {
        let url = try writeRedPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await warmThumbnail(for: url)
        let coordinator = CommandCoordinator.isolated()
        coordinator.subjectVM.results = [fileSubject(url)]
        coordinator.subjectVM.selectedIndex = 0

        let pixels = try render(Card(coordinator: coordinator), size: PanelLayout.cardWidth)

        let inset = Style.cardInset
        let far = PanelLayout.cardWidth - inset
        let mid = PanelLayout.cardWidth / 2
        #expect(pixels.isRed(inset + 1, mid))
        #expect(pixels.isRed(far - 1, mid))
        #expect(pixels.isRed(mid, inset + 1))
        #expect(pixels.isRed(mid, mid))
        #expect(pixels.isClear(inset - 1, mid))
        #expect(pixels.isClear(mid, inset - 1))
        // Rounded with the glass, not square.
        #expect(pixels.isClear(inset + 1, inset + 1))
    }

    /// The unfocused Card steps back 10pt on every side, picture and all.
    @Test func anUnfocusedCardsPictureFollowsTheEmphasisInset() async throws {
        let url = try writeRedPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = CommandCoordinator.isolated()
        coordinator.subjectVM.results = [fileSubject(url)]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        let chosen = try #require(coordinator.selectedSubject?.thumbnailURL)
        try await warmThumbnail(for: chosen)

        let pixels = try render(Card(coordinator: coordinator), size: PanelLayout.cardWidth)

        let edge = Style.cardInset + Style.unfocusedCardShrink
        let mid = PanelLayout.cardWidth / 2
        // Red at the unfocused content's opacity.
        let inside = pixels.rgba(edge + 1, mid)
        #expect(inside.a > 100 && inside.r > 2 * inside.g && inside.r > 2 * inside.b, "\(pixels.at(edge + 1, mid))")
        #expect(pixels.isClear(edge - 1, mid), "\(pixels.at(edge - 1, mid))")
        #expect(pixels.isClear(mid, edge - 1), "\(pixels.at(mid, edge - 1))")
    }

    /// No thumbnail, no picture: the icon in the middle and the glass bare at
    /// its edges, as before.
    @Test func aSubjectWithoutAThumbnailKeepsTheIconLayout() throws {
        let icon = NSImage(cgImage: Self.redImage(width: 152, height: 152), size: NSSize(width: 76, height: 76))
        let coordinator = CommandCoordinator.isolated()
        coordinator.subjectVM.results = [
            Subject(displayName: "Folder", path: "/tmp", url: URL(fileURLWithPath: "/tmp"), icon: icon, kind: .folder)
        ]
        coordinator.subjectVM.selectedIndex = 0

        let pixels = try render(Card(coordinator: coordinator), size: PanelLayout.cardWidth)

        let mid = PanelLayout.cardWidth / 2
        #expect(pixels.isClear(Style.cardInset + 1, mid))
        #expect(pixels.isClear(mid, Style.cardInset + 1))
        #expect(pixels.isRed(mid, mid - 20))
    }
}
