import AppKit
import CoreImage
import ImageIO

/// A picture for the photos page, decoded and sized for the 1280x720 canvas ahead of time, so the page only draws it.
struct Photo: Equatable, @unchecked Sendable {  // CGImage is immutable
    let id: String  // its PhotoRef's id
    let image: CGImage
    let backdrop: CGImage?  // a blurred copy that fills the screen behind a picture shown whole
    let taken: Date?

    static func == (a: Photo, b: Photo) -> Bool { a.id == b.id }
}

/// One of the photos page's pictures: a file in `photos.folder`, or a picture in the Photos app's `photos.album`.
enum PhotoRef: Hashable, Sendable {
    case file(URL)
    case asset(String)  // a PHAsset's localIdentifier

    var id: String {
        switch self {
        case .file(let url): url.path
        case .asset(let id): "photos:" + id
        }
    }
}

/// The photos page: the pictures in `photos.album` (an album in the Photos app) or else `photos.folder` (and its
/// subfolders), one per visit, shuffled. They are listed every 5 minutes, and the next picture is decoded while the
/// page is away, off the main thread, so it is ready when the page comes round. Nothing is cached on disk.
@MainActor
final class PhotosService {
    nonisolated private static let kinds: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "webp"]

    private let dash: Dashboard
    private var cfg: Config.Photos?
    private var refs: [PhotoRef] = []
    private var queue: [PhotoRef] = []
    private var listedAt = Date.distantPast
    private var busy = false
    private var showing = false
    private var stale = true  // the photo on hand has been shown: decode the next one
    private var note = ""

    init(dash: Dashboard) {
        self.dash = dash
    }

    func apply(_ cfg: Config.Photos, enabled: Bool) {
        let wanted = enabled && !(cfg.folder.isEmpty && cfg.album.isEmpty) ? cfg : nil
        guard wanted != self.cfg else { return }
        self.cfg = wanted
        refs = []
        queue = []
        listedAt = .distantPast
        stale = true
        if wanted == nil { dash.photo = nil }
    }

    func tick() {
        guard let cfg, !busy else { return }
        let onPage = dash.page == .photos
        if showing && !onPage { stale = true }  // it has had its turn
        showing = onPage
        if Date().timeIntervalSince(listedAt) >= 300 { return list(cfg) }
        if stale && !onPage { next(cfg) }
    }

    /// For `deskdash snapshot`: one picture from the folder, now. The Photos app's albums are left out: a bare binary
    /// asking for the library would be asking on behalf of Terminal.
    func loadOnce(_ cfg: Config.Photos) async {
        let urls = await Task.detached(priority: .utility) { Self.list(cfg.folder) }.value
        guard let url = cfg.shuffle ? urls.randomElement() : urls.first else { return }
        dash.photo = await Task.detached(priority: .utility) { Self.load(url, fill: cfg.fill) }.value
    }

    private func list(_ cfg: Config.Photos) {
        busy = true
        listedAt = Date()
        Task {
            let found: [PhotoRef]
            if cfg.album.isEmpty {
                found = await Task.detached(priority: .utility) { Self.list(cfg.folder).map(PhotoRef.file) }.value
                say(found.isEmpty ? "photos: no pictures in \(cfg.folder)" : "photos: \(found.count) pictures in \(cfg.folder)")
            } else {
                switch await PhotoLibrary.list(album: cfg.album) {
                case .denied:
                    found = []
                    say("photos: deskdash may not read the Photos library; System Settings → Privacy & Security → Photos")
                case .noAlbum(let albums):
                    found = []
                    say("photos: no album named '\(cfg.album)' in the Photos app. Its albums: \(albums.joined(separator: ", "))")
                case .pictures(let ids):
                    found = ids.map(PhotoRef.asset)
                    say("photos: \(ids.count) pictures in the album '\(cfg.album)'")
                }
            }
            busy = false
            guard self.cfg == cfg else { return }
            refs = found
            queue.removeAll { !found.contains($0) }
            if found.isEmpty { dash.photo = nil }
        }
    }

    private func next(_ cfg: Config.Photos) {
        if queue.isEmpty { queue = cfg.shuffle ? refs.shuffled() : refs }
        // Never the same picture twice in a row, even across a reshuffle.
        if queue.count > 1, queue.first?.id == dash.photo?.id { queue.append(queue.removeFirst()) }
        guard !queue.isEmpty else { return }
        let ref = queue.removeFirst()
        busy = true
        Task {
            let photo: Photo? = switch ref {
            case .file(let url): await Task.detached(priority: .utility) { Self.load(url, fill: cfg.fill) }.value
            case .asset(let id): await PhotoLibrary.load(id, fill: cfg.fill)
            }
            busy = false
            guard self.cfg == cfg else { return }
            if let photo {
                dash.photo = photo
                stale = false
            } else {
                refs.removeAll { $0 == ref }  // unreadable: skip it until the next listing
            }
        }
    }

    /// `deskdash ctl albums`: the Photos app's album names, in the log, to pick `photos.album` from.
    func logAlbums() {
        Task {
            switch await PhotoLibrary.list(album: "") {
            case .denied: log("photos: deskdash may not read the Photos library; System Settings → Privacy & Security → Photos")
            case .noAlbum(let albums): log("photos: albums in the Photos app: \(albums.joined(separator: ", "))")
            case .pictures: break
            }
        }
    }

    private func say(_ text: String) {
        guard text != note else { return }
        note = text
        log(text)
    }

    nonisolated private static func list(_ folder: String) -> [URL] {
        guard !folder.isEmpty else { return [] }
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var out: [URL] = []
        for case let url as URL in walk where kinds.contains(url.pathExtension.lowercased()) {
            out.append(url)
            if out.count >= 10_000 { break }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Decodes at most 2048 px on the long side, turned upright, and, for a picture shown whole, a blurred copy cropped
    /// to fill the screen behind it.
    nonisolated private static func load(_ url: URL, fill: Bool) -> Photo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let taken = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap { exifDate.date(from: $0) }
        return Photo(id: url.path, image: image, backdrop: fill ? nil : backdrop(of: image), taken: taken)
    }

    private nonisolated(unsafe) static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    nonisolated static func backdropForDemo(_ image: CGImage) -> CGImage? { backdrop(of: image) }

    nonisolated static func backdrop(for image: CGImage) -> CGImage? { backdrop(of: image) }

    /// The picture cropped to fill 1280x720 at a quarter size, blurred, and darkened, done once here rather than by
    /// SwiftUI on every redraw.
    nonisolated private static func backdrop(of image: CGImage) -> CGImage? {
        let target = CGSize(width: 320, height: 180)
        let scale = max(target.width / CGFloat(image.width), target.height / CGFloat(image.height))
        let input = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 12)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.2])  // scales the light: colors keep their hue
        let crop = CGRect(x: (input.extent.width - target.width) / 2, y: (input.extent.height - target.height) / 2,
                          width: target.width, height: target.height)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: crop)
    }
}

extension Photo {
    /// For `snapshot --demo` and the README: a drawn sunset over hills, so no one's picture is in the repository.
    nonisolated(unsafe) static let demo: Photo? = {
        let (w, h) = (1600, 1200)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.55, green: 0.33, blue: 0.62, alpha: 1),
            CGColor(srgbRed: 0.13, green: 0.16, blue: 0.38, alpha: 1),
        ] as CFArray, locations: [0, 0.55, 1])!
        c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 380), end: CGPoint(x: 0, y: CGFloat(h)), options: [.drawsBeforeStartLocation])
        c.setFillColor(CGColor(srgbRed: 1, green: 0.86, blue: 0.55, alpha: 1))
        c.fillEllipse(in: CGRect(x: 980, y: 420, width: 220, height: 220))
        for (i, color) in [(0, CGColor(srgbRed: 0.24, green: 0.2, blue: 0.36, alpha: 1)),
                           (1, CGColor(srgbRed: 0.12, green: 0.11, blue: 0.22, alpha: 1))] {
            let base = CGFloat(500 - i * 160)
            c.move(to: CGPoint(x: 0, y: 0))
            c.addLine(to: CGPoint(x: 0, y: base))
            c.addCurve(to: CGPoint(x: CGFloat(w), y: base - 40), control1: CGPoint(x: 500, y: base + 220 - CGFloat(i) * 120),
                       control2: CGPoint(x: 1100, y: base - 200))
            c.addLine(to: CGPoint(x: CGFloat(w), y: 0))
            c.setFillColor(color)
            c.fillPath()
        }
        guard let image = c.makeImage() else { return nil }
        return Photo(id: "demo", image: image, backdrop: PhotosService.backdropForDemo(image), taken: nil)
    }()
}
