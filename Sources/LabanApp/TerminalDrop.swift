import AppKit
import Foundation
import LabanCore

enum TerminalDrop {
  struct ResolvedDrop: Equatable {
    var urls: [URL]
    var sourceKinds: [String]
  }

  enum DropError: Error, Equatable {
    case noReadableItems
    case imageEncodingFailed
  }

  static let acceptedTypes: [NSPasteboard.PasteboardType] = [
    .fileURL,
    .URL,
    .png,
    .tiff,
    NSPasteboard.PasteboardType("public.file-url"),
    NSPasteboard.PasteboardType("public.image"),
    NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
    NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
    NSPasteboard.PasteboardType("com.apple.NSFilePromiseItem"),
  ]

  private static let promiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "laban.drop.file-promises"
    queue.qualityOfService = .userInitiated
    return queue
  }()

  static func canRead(_ pasteboard: NSPasteboard) -> Bool {
    !readFileURLs(from: pasteboard).isEmpty
      || containsFilePromises(pasteboard)
      || containsImages(pasteboard)
  }

  static func resolve(
    _ pasteboard: NSPasteboard,
    completion: @escaping (Result<ResolvedDrop, Error>) -> Void
  ) {
    let fileURLs = readFileURLs(from: pasteboard)
    let images = readImages(from: pasteboard)
    let promises = readFilePromises(from: pasteboard)

    if promises.isEmpty {
      do {
        var urls = fileURLs
        var sourceKinds = Array(repeating: "fileURL", count: fileURLs.count)
        if urls.isEmpty, !images.isEmpty {
          let imageURLs = try materializeImages(images)
          urls.append(contentsOf: imageURLs)
          sourceKinds.append(contentsOf: Array(repeating: "imageData", count: imageURLs.count))
        }
        guard !urls.isEmpty else {
          completion(.failure(DropError.noReadableItems))
          return
        }
        completion(.success(ResolvedDrop(urls: urls, sourceKinds: sourceKinds)))
      } catch {
        completion(.failure(error))
      }
      return
    }

    do {
      let destination = try makeDropDirectory()
      receivePromises(promises, destination: destination) { result in
        do {
          let promisedURLs = try result.get()
          var urls = fileURLs + promisedURLs
          var sourceKinds = Array(repeating: "fileURL", count: fileURLs.count)
          sourceKinds.append(contentsOf: Array(repeating: "filePromise", count: promisedURLs.count))
          if urls.isEmpty, !images.isEmpty {
            let imageURLs = try materializeImages(images, in: destination)
            urls.append(contentsOf: imageURLs)
            sourceKinds.append(contentsOf: Array(repeating: "imageData", count: imageURLs.count))
          }
          guard !urls.isEmpty else {
            completion(.failure(DropError.noReadableItems))
            return
          }
          completion(.success(ResolvedDrop(urls: urls, sourceKinds: sourceKinds)))
        } catch {
          if !fileURLs.isEmpty {
            completion(
              .success(
                ResolvedDrop(
                  urls: fileURLs,
                  sourceKinds: Array(repeating: "fileURL", count: fileURLs.count)
                )))
          } else if !images.isEmpty {
            do {
              let imageURLs = try materializeImages(images, in: destination)
              completion(
                .success(
                  ResolvedDrop(
                    urls: imageURLs,
                    sourceKinds: Array(repeating: "imageData", count: imageURLs.count)
                  )))
            } catch {
              completion(.failure(error))
            }
          } else {
            completion(.failure(error))
          }
        }
      }
    } catch {
      completion(.failure(error))
    }
  }

  static func terminalText(for urls: [URL]) -> String {
    TerminalDropText.format(urls: urls)
  }

  static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
    return objects.compactMap { object in
      guard let url = object as? URL, url.isFileURL else { return nil }
      return url
    }
  }

  static func containsImages(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
  }

  static func readImages(from pasteboard: NSPasteboard) -> [NSImage] {
    pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
  }

  static func materializeImages(_ images: [NSImage], in directory: URL? = nil) throws -> [URL] {
    guard !images.isEmpty else { return [] }
    let dropDirectory = try directory ?? makeDropDirectory()
    return try images.enumerated().map { index, image in
      guard let png = pngData(from: image) else {
        throw DropError.imageEncodingFailed
      }
      let url = dropDirectory.appendingPathComponent(
        String(format: "image-%02d.png", index + 1),
        isDirectory: false
      )
      try png.write(to: url, options: .atomic)
      return url
    }
  }

  static func defaultDropRoot() -> URL {
    let appSupport =
      FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory())

    return
      appSupport
      .appendingPathComponent("Laban", isDirectory: true)
      .appendingPathComponent("drops", isDirectory: true)
  }

  static func makeDropDirectory(root: URL = defaultDropRoot()) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    pruneOldDropDirectories(root: root)
    let stamp = dropTimestamp()
    let url = root.appendingPathComponent("drop-\(stamp)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func containsFilePromises(_ pasteboard: NSPasteboard) -> Bool {
    !readFilePromises(from: pasteboard).isEmpty
  }

  private static func readFilePromises(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
    pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
      as? [NSFilePromiseReceiver] ?? []
  }

  private static func receivePromises(
    _ promises: [NSFilePromiseReceiver],
    destination: URL,
    completion: @escaping (Result<[URL], Error>) -> Void
  ) {
    guard !promises.isEmpty else {
      completion(.success([]))
      return
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var urls = [URL?](repeating: nil, count: promises.count)
    var firstError: Error?

    for (index, promise) in promises.enumerated() {
      group.enter()
      promise.receivePromisedFiles(
        atDestination: destination,
        options: [:],
        operationQueue: promiseQueue
      ) { fileURL, error in
        lock.lock()
        urls[index] = fileURL
        if firstError == nil, let error {
          firstError = error
        }
        lock.unlock()
        group.leave()
      }
    }

    group.notify(queue: .main) {
      let resolved = urls.compactMap { $0 }
      if resolved.isEmpty, let firstError {
        completion(.failure(firstError))
      } else {
        completion(.success(resolved))
      }
    }
  }

  private static func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    return rep.representation(using: .png, properties: [:])
  }

  private static func pruneOldDropDirectories(root: URL, now: Date = Date()) {
    let fm = FileManager.default
    let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
    guard
      let entries = try? fm.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    for entry in entries {
      let values = try? entry.resourceValues(
        forKeys: [.contentModificationDateKey, .isDirectoryKey])
      guard values?.isDirectory == true,
        (values?.contentModificationDate ?? now) < cutoff
      else { continue }
      try? fm.removeItem(at: entry)
    }
  }

  private static func dropTimestamp(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: now)
  }
}
