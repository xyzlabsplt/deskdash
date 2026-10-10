import AppKit
import Photos

/// The Photos app's library, for `photos.album`, read through PhotoKit. macOS asks once whether deskdash may read the
/// library (System Settings → Privacy & Security → Photos), and then remembers it for deskdash.app. Pictures kept only in
/// iCloud ("Optimize Mac Storage") are downloaded at the size the page needs.
enum PhotoLibrary {
    enum Listing: Sendable {
        case denied
        case noAlbum([String])  // the albums there are
        case pictures([String])  // the album's pictures, as PHAsset localIdentifiers, oldest first
    }

    /// The pictures in the album named `name` (any case): your albums, shared albums, and smart albums such as
    /// Favorites, by the names the Photos app shows.
    static func list(album name: String) async -> Listing {
        guard await authorized() else { return .denied }
        return await Task.detached(priority: .utility) { listNow(album: name) }.value
    }

    nonisolated private static func listNow(album name: String) -> Listing {
        var match: PHAssetCollection?
        var names: [String] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { album, _, _ in
                guard let title = album.localizedTitle, !title.isEmpty else { return }
                if album.estimatedAssetCount != 0 { names.append(title) }
                if match == nil, title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                    match = album
                }
            }
        }
        guard let match else { return .noAlbum(Array(Set(names)).sorted()) }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var ids: [String] = []
        PHAsset.fetchAssets(in: match, options: options).enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return .pictures(ids)
    }

    /// One picture, at most 2048 px on the long side, from iCloud if the Mac does not keep it.
    static func load(_ id: String, fill: Bool) async -> Photo? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat  // one answer, not a quick one and then a better one
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let taken = asset.creationDate
        let image: CGImage? = await withCheckedContinuation { done in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2048, height: 2048),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                done.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
        guard let image else { return nil }
        let backdrop = fill ? nil : await Task.detached(priority: .utility) { PhotosService.backdrop(for: image) }.value
        return Photo(id: PhotoRef.asset(id).id, image: image, backdrop: backdrop, taken: taken)
    }

    private static func authorized() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        default: return false
        }
    }
}
