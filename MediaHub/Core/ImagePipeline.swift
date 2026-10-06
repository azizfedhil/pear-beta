import SwiftUI
import ImageIO

/// Decoded images, shared by every view. NSCache is thread-safe, so views can ask it synchronously: a poster that was
/// already on screen comes back instantly, with no placeholder, no fade and no hop onto the pipeline actor.
enum ImageMemory {
    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 60 << 20
        return c
    }()

    static func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.absoluteString)@\(Int(maxPixel))" as NSString
    }

    static func get(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, maxPixel))
    }
}

/// Downsamples to display size via ImageIO (no full-size bitmaps in memory), caches in
/// ImageMemory + URLCache, and cancels with the view's task when scrolled offscreen.
///
/// - One download per URL, however many views (and sizes) want it: the hero artwork, its tint colour and an
///   episode still all share a single request. The download is cancelled once the last interested view goes away.
/// - Decoding runs off the actor, so a big hero JPEG never makes cached posters wait behind it.
/// - Bitmaps are never larger than the source image, so a 780 px backdrop isn't stretched into a 2400 px one.
actor ImagePipeline {
    static let shared = ImagePipeline()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 30 << 20, diskCapacity: 300 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()
    private var colorCache: [URL: UIColor] = [:]
    private var flights: [URL: DataFlight] = [:]
    private var nextWaiter = 0

    /// One running download and the views waiting for it.
    private final class DataFlight: @unchecked Sendable {
        let task: Task<Data?, Never>
        var waiters = Set<Int>()
        init(_ task: Task<Data?, Never>) { self.task = task }
    }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let hit = ImageMemory.get(url, maxPixel: maxPixel) { return hit }
        guard let data = await download(url), !Task.isCancelled else { return nil }
        let img = await Task.detached(priority: .userInitiated) { Self.decode(data, maxPixel: maxPixel) }.value
        guard let img else { return nil }
        ImageMemory.cache.setObject(img, forKey: ImageMemory.key(url, maxPixel),
                                    cost: img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        return img
    }

    // MARK: Download (shared, cancel when nobody is waiting any more)

    private func download(_ url: URL) async -> Data? {
        let flight: DataFlight
        if let running = flights[url] {
            flight = running
        } else {
            let session = session
            let task = Task.detached(priority: .userInitiated) { () -> Data? in
                guard let (data, response) = try? await session.data(from: url) else { return nil }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
                return data
            }
            flight = DataFlight(task)
            flights[url] = flight
        }
        nextWaiter += 1
        let id = nextWaiter
        flight.waiters.insert(id)
        let data = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { await self.leave(url, flight, id) }
        }
        flight.waiters.remove(id)
        if flight.waiters.isEmpty, flights[url] === flight { flights[url] = nil }
        return data
    }

    private func leave(_ url: URL, _ flight: DataFlight, _ id: Int) {
        flight.waiters.remove(id)
        guard flight.waiters.isEmpty else { return }
        flight.task.cancel()
        if flights[url] === flight { flights[url] = nil }
    }

    // MARK: Decode

    private static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var target = maxPixel
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            target = min(maxPixel, CGFloat(max(w, h)))
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Average colour

    /// Average colour of an image, nudged to be vivid but dark enough to sit behind white text.
    /// Used for the ambient glow behind the Home hero.
    func averageColor(for url: URL) async -> UIColor? {
        if let hit = colorCache[url] { return hit }
        guard let cg = await image(for: url, maxPixel: 48)?.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let base = UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let tuned = UIColor(hue: h, saturation: min(1, s * 1.3 + 0.08), brightness: min(max(b, 0.35), 0.62), alpha: 1)
        colorCache[url] = tuned
        return tuned
    }
}

struct RemoteImage: View {
    let url: URL?
    /// Longest edge in points; converted to pixels for downsampling.
    let size: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var failed = false

    private var pixels: CGFloat { size * scale }

    var body: some View {
        // A memory hit needs no placeholder, no fade and no task round trip. Lazy stacks recreate their cells
        // constantly while you scroll, so this is what keeps scrolling back over posters flicker-free and cheap.
        let shown = url.flatMap { ImageMemory.get($0, maxPixel: pixels) } ?? image
        Color(.secondarySystemFill)
            .overlay {
                if let shown {
                    Image(uiImage: shown).resizable().scaledToFill().transition(.opacity)
                } else if failed {
                    Image(systemName: "film").font(.title2).foregroundStyle(.tertiary)
                } else {
                    Shimmer()
                }
            }
            .clipped()
            .task(id: url) {
                failed = false
                guard let url else { failed = true; return }
                if let hit = ImageMemory.get(url, maxPixel: pixels) { image = hit; return }
                let img = await ImagePipeline.shared.image(for: url, maxPixel: pixels)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { image = img }
                if img == nil { failed = true }
            }
    }
}

/// Soft highlight sweeping across a placeholder while its image loads.
/// Driven by the wall clock, so every placeholder on screen sweeps in step, at 30 fps (a slow highlight doesn't need
/// more). Static under Reduce Motion and in Low Power Mode.
struct Shimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion || PowerMode.shared.saving {
                Color.white.opacity(0.04)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    GeometryReader { g in
                        let phase = (tl.date.timeIntervalSinceReferenceDate / 1.4).truncatingRemainder(dividingBy: 1)
                        LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6)
                            .offset(x: -g.size.width * 0.6 + CGFloat(phase) * g.size.width * 1.6)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Aspect-fit variant for transparent logos.
struct LogoImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        let shown = ImageMemory.get(url, maxPixel: 600) ?? image
        Group {
            if let shown { Image(uiImage: shown).resizable().scaledToFit() }
        }
        .task(id: url) {
            if ImageMemory.get(url, maxPixel: 600) != nil { return }
            image = await ImagePipeline.shared.image(for: url, maxPixel: 600)
        }
    }
}
