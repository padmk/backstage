// Photos through PhotoKit: the system photo library, without the Photos app or its window, also while the screen
// is locked. macOS grants read and write together; these operations only find and copy out. PhotoKit has no text,
// people or place search, so finding is by date, type, album and favorite.

import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

private let accessRequestSeconds = 170
private let exportSeconds: TimeInterval = 120
// A video original larger than this is not copied: an agent has no use for it, and it would fill the disk.
private let maxExportBytes = 4 << 30
private let defaultJPEGPixels = 2048
private let maxJPEGPixels = 8192
private let defaultItems = 50
private let maxItems = 200

func photosAccessState() -> GrantState {
  switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
  case .authorized, .limited: .granted
  case .notDetermined: .notAsked
  default: .denied
  }
}

// Shows macOS's prompt when it has not asked yet; the wait holds no lock.
func requestPhotosAccess() {
  guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else { return }
  let answered = DispatchSemaphore(value: 0)
  PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in answered.signal() }
  _ = answered.wait(timeout: .now() + .seconds(accessRequestSeconds))
}

// Results say so when the user let Backstage see only part of the library.
private func noteLimited(_ result: JSON) -> JSON {
  guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return result }
  return result.merging(["limited": true]) { $1 }
}

private func asset(_ id: String) throws -> PHAsset {
  guard let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
    throw HelperError(code: "not_found", message: "No photo or video has the id \(id). Use list_media.")
  }
  return found
}

private func describe(_ asset: PHAsset) -> JSON {
  var item: JSON = ["id": asset.localIdentifier]
  if let created = asset.creationDate { item["created"] = timeText(created) }
  switch asset.mediaType {
  case .image: item["type"] = "photo"
  case .video: item["type"] = "video"
  case .audio: item["type"] = "audio"
  default: item["type"] = "other"
  }
  if asset.mediaSubtypes.contains(.photoScreenshot) { item["screenshot"] = true }
  if asset.mediaSubtypes.contains(.photoLive) { item["live"] = true }
  item["width"] = asset.pixelWidth
  item["height"] = asset.pixelHeight
  if asset.mediaType == .video { item["duration"] = (asset.duration * 10).rounded() / 10 }
  if asset.isFavorite { item["favorite"] = true }
  if let name = PHAssetResource.assetResources(for: asset).first?.originalFilename { item["filename"] = name }
  return item
}

private let listAlbums = Operation(
  name: "list_albums", summary: "List your albums with their ids, titles and item counts", effect: .reads,
  arguments: [Argument(name: "limit", kind: .integer, required: false, description: "Most albums to return; default 100", minimum: 1, maximum: 1000)]
) { arguments in
  let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
  var albums: [JSON] = []
  let count = min(collections.count, arguments["limit"] as? Int ?? 100)
  for index in 0..<count {
    let album = collections.object(at: index)
    let items = album.estimatedAssetCount == NSNotFound ? PHAsset.fetchAssets(in: album, options: nil).count : album.estimatedAssetCount
    albums.append(["id": album.localIdentifier, "title": album.localizedTitle ?? "", "count": items])
  }
  return noteLimited(["total": collections.count, "has_more": collections.count > count, "albums": albums])
}

private let listMedia = Operation(
  name: "list_media", summary: "List photos and videos, newest first, filtered by date, type, album or favorite", effect: .reads,
  arguments: [
    Argument(name: "since", kind: .string, required: false, description: "Only items taken from this time on: an ISO 8601 date or time"),
    Argument(name: "until", kind: .string, required: false, description: "Only items taken before this time"),
    Argument(name: "type", kind: .string, required: false, description: "photo or video; default both", allowed: ["photo", "video"]),
    Argument(name: "screenshots", kind: .boolean, required: false, description: "Only screenshots"),
    Argument(name: "live", kind: .boolean, required: false, description: "Only Live Photos"),
    Argument(name: "favorites", kind: .boolean, required: false, description: "Only favorites"),
    Argument(name: "album", kind: .string, required: false, description: "Album id from list_albums"),
    Argument(name: "before", kind: .string, required: false, description: "Only items after this one in the list; pass the last id to read on"),
    Argument(name: "limit", kind: .integer, required: false, description: "Most items to return; default \(defaultItems)", minimum: 1, maximum: maxItems),
  ]
) { arguments in
  var predicates: [NSPredicate] = []
  if let since = optionalString(arguments, "since") { predicates.append(NSPredicate(format: "creationDate >= %@", try moment(since, key: "since").date as NSDate)) }
  if let until = optionalString(arguments, "until") { predicates.append(NSPredicate(format: "creationDate < %@", try moment(until, key: "until").date as NSDate)) }
  switch arguments["type"] as? String {
  case "photo": predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
  case "video": predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
  default: break
  }
  for (key, subtype) in [("screenshots", PHAssetMediaSubtype.photoScreenshot), ("live", .photoLive)] where arguments[key] as? Bool == true {
    predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", subtype.rawValue))
  }
  if arguments["favorites"] as? Bool == true { predicates.append(NSPredicate(format: "favorite == YES")) }
  // Newest first; hidden items and the other shots of a burst stay out, as in the library's own views.
  let options = PHFetchOptions()
  options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
  if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
  let found: PHFetchResult<PHAsset>
  if let album = optionalString(arguments, "album") {
    guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else {
      throw HelperError(code: "not_found", message: "No album has the id \(album). Use list_albums.")
    }
    found = PHAsset.fetchAssets(in: collection, options: options)
  } else {
    found = PHAsset.fetchAssets(with: options)
  }
  // The position after the item named, in this same ordering, so items sharing a time are neither skipped nor repeated.
  var start = 0
  if let before = optionalString(arguments, "before") {
    let position = found.index(of: try asset(before))
    guard position != NSNotFound else { throw HelperError(code: "not_found", message: "\(before) is not among these items.") }
    start = position + 1
  }
  let end = min(found.count, start + (arguments["limit"] as? Int ?? defaultItems))
  let media = start < end ? (start..<end).map { describe(found.object(at: $0)) } : []
  return noteLimited(["total": found.count, "has_more": end < found.count, "media": media])
}

// MARK: Export

private enum Fetched {
  case done
  case needsNetwork
  case failed(String)
  case tooLarge
  case timedOut
}

// Streams one resource into a file. The request is cancelled on a timeout or past the size limit, and a callback
// that arrives after that changes nothing.
private func fetch(_ resource: PHAssetResource, to url: URL, network: Bool) -> Fetched {
  guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
    let file = try? FileHandle(forWritingTo: url) else { return .failed("The copy could not be written.") }
  defer { try? file.close() }
  let options = PHAssetResourceRequestOptions()
  options.isNetworkAccessAllowed = network
  let lock = NSLock()
  var finished = false
  var written = 0
  var outcome = Fetched.done
  let done = DispatchSemaphore(value: 0)
  let manager = PHAssetResourceManager.default()
  var request: PHAssetResourceDataRequestID = 0
  request = manager.requestData(for: resource, options: options, dataReceivedHandler: { data in
    // The request is cancelled outside the lock, in case cancelling calls back into these handlers.
    let stop: Bool = lock.withLock {
      guard !finished else { return false }
      written += data.count
      var failure: Fetched?
      if written > maxExportBytes {
        failure = .tooLarge
      } else {
        do { try file.write(contentsOf: data) } catch { failure = .failed("The copy could not be written: \(error.localizedDescription)") }
      }
      guard let failure else { return false }
      finished = true
      outcome = failure
      done.signal()
      return true
    }
    if stop { manager.cancelDataRequest(request) }
  }, completionHandler: { error in
    lock.withLock {
      guard !finished else { return }
      finished = true
      if let error = error as NSError? {
        let needsNetwork = error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.networkAccessRequired.rawValue
        outcome = needsNetwork ? .needsNetwork : .failed(error.localizedDescription)
      }
      done.signal()
    }
  })
  if done.wait(timeout: .now() + exportSeconds) == .timedOut {
    lock.withLock {
      if !finished {
        finished = true
        outcome = .timedOut
      }
    }
    manager.cancelDataRequest(request)
  }
  return lock.withLock { outcome }
}

// A name for the copy from the original's, without folders or a leading dot.
private func safeName(_ original: String, fallback: String) -> String {
  let base = (original as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
  let trimmed = base.drop { $0 == "." }
  return trimmed.isEmpty ? fallback : String(trimmed)
}

private let export = Operation(
  name: "export", summary: "Copy a photo or video to a new temporary file: the original, or a photo as a JPEG of a given size", effect: .reads,
  arguments: [
    Argument(name: "id", kind: .string, required: true, description: "Item id from list_media"),
    Argument(name: "format", kind: .string, required: false, description: "original (default), or jpeg for a photo", allowed: ["original", "jpeg"]),
    Argument(name: "max_pixels", kind: .integer, required: false, description: "For jpeg, the longer side in pixels; default \(defaultJPEGPixels)", minimum: 64, maximum: maxJPEGPixels),
  ]
) { arguments in
  let item = try asset(try string(arguments, "id"))
  let jpeg = arguments["format"] as? String == "jpeg"
  guard !jpeg || item.mediaType == .image else {
    throw HelperError(code: "invalid_arguments", message: "Only a photo can become a JPEG; export a video as original.")
  }
  // The current version: the edited one when there is one, else the original.
  let resources = PHAssetResource.assetResources(for: item)
  let preferred: [PHAssetResourceType] = item.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
  guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first else {
    throw HelperError(code: "not_found", message: "This item has no photo or video to copy.")
  }
  let folder = try newCopyFolder(.photosExport)
  let name = safeName(resource.originalFilename, fallback: "item")
  let original = folder.appendingPathComponent(jpeg ? ".source-" + name : name)
  // Without the network first, so an item that is only in iCloud is reported as downloaded.
  var downloaded = false
  var outcome = fetch(resource, to: original, network: false)
  if case .needsNetwork = outcome {
    downloaded = true
    try? FileManager.default.removeItem(at: original)
    outcome = fetch(resource, to: original, network: true)
  }
  switch outcome {
  case .done: break
  case .needsNetwork, .failed:
    try? FileManager.default.removeItem(at: folder)
    if case .failed(let reason) = outcome { throw HelperError(code: "action_failed", message: "The item could not be copied: \(reason)") }
    throw HelperError(code: "not_found", message: "The item is in iCloud and could not be downloaded.")
  case .tooLarge:
    try? FileManager.default.removeItem(at: folder)
    throw HelperError(code: "action_failed", message: "The item is larger than \(maxExportBytes >> 30) GB, so it was not copied.")
  case .timedOut:
    try? FileManager.default.removeItem(at: folder)
    throw HelperError(code: "timeout", message: "Copying the item took longer than \(Int(exportSeconds)) s\(downloaded ? ", downloading it from iCloud" : "").")
  }
  var result: JSON = ["id": item.localIdentifier, "format": jpeg ? "jpeg" : "original"]
  if downloaded { result["downloaded"] = true }
  let path: URL
  if jpeg {
    // Drawn from the original with its orientation applied and no metadata, so no location travels with it.
    path = folder.appendingPathComponent(((name as NSString).deletingPathExtension) + ".jpg")
    let pixels = arguments["max_pixels"] as? Int ?? defaultJPEGPixels
    defer { try? FileManager.default.removeItem(at: original) }
    guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: pixels,
      ] as CFDictionary),
      let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      try? FileManager.default.removeItem(at: folder)
      throw HelperError(code: "action_failed", message: "The photo could not be turned into a JPEG.")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: folder)
      throw HelperError(code: "action_failed", message: "The JPEG could not be written.")
    }
    result["width"] = image.width
    result["height"] = image.height
  } else {
    path = original
    // An original keeps its metadata. A photo's own bytes say whether they hold a place; a video's are not read,
    // so it may hold one. The library's location can differ from either.
    if item.mediaType == .image {
      let properties = CGImageSourceCreateWithURL(original as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
      if properties?[kCGImagePropertyGPSDictionary] != nil { result["contains_location"] = true }
    } else {
      result["may_contain_location"] = true
    }
  }
  let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
  guard size > 0 else {
    try? FileManager.default.removeItem(at: folder)
    throw HelperError(code: "action_failed", message: "The copy came out empty.")
  }
  result["path"] = path.path
  result["bytes"] = size
  return noteLimited(result)
}

let photosKnowledge = AppKnowledge(
  bundleId: "com.apple.Photos", name: "Photos", summary: "Find photos and videos by date, type, album or favorite, and copy them out, without the Photos app",
  access: "Find and copy your photos and videos, even while Photos is closed",
  hints: [
    "list_media finds by date, type, album and favorite only; PhotoKit has no text, people or place search. For those, use Photos' window.",
  ],
  pitfalls: [
    "Operations reach the System Photo Library, which can differ from the library Photos has open.",
    "An original keeps its metadata, including where it was taken (contains_location for a photo, may_contain_location for a video); a jpeg export carries none.",
    "export may download an item from iCloud first (downloaded: true), which can take a while for a video.",
  ],
  operations: [listAlbums, listMedia, export])
