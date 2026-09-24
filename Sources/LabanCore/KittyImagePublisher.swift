import Foundation
import LabanRenderer
import LabanTerminalCore

/// Publishes one session's Kitty graphics image pixels to
/// `FrameImageStore.shared` so renderers can draw the `texturedQuad`s that
/// `FrameProducer` emits for the snapshot's placements.
///
/// Resource ids are libghostty image generation stamps (process-wide unique),
/// so a new id means new pixels: each image generation is copied out of the
/// terminal core once. Ids no snapshot has referenced for
/// `retentionSnapshots` snapshots are removed from the store, which leaves
/// in-flight frames time to finish with them; `removeAll` runs when the
/// session closes. Not thread-safe; `Session` calls it under its handle lock.
final class KittyImagePublisher {
  /// ~2 s at 60 Hz. A frame that still references a removed id would draw
  /// nothing for that quad, never crash.
  static let retentionSnapshots = 120

  private let store: FrameImageStore
  private var lastSeen: [UInt64: Int] = [:]
  private var tick = 0

  init(store: FrameImageStore = .shared) {
    self.store = store
  }

  /// Copies pixels for placements whose image generation is not yet
  /// published, then retires ids that have gone unreferenced.
  func publish(snapshot: UnsafePointer<LabanSnapshot>, session handle: OpaquePointer) {
    tick &+= 1
    let snap = snapshot.pointee
    if let placements = snap.image_placements {
      for i in 0..<snap.image_placement_count {
        let placement = placements[i]
        let id = placement.image_generation
        if lastSeen[id] == nil, !store.contains(id),
          let image = Self.copyImage(handle, placement.image_id, id)
        {
          store.put(image, for: id)
        }
        lastSeen[id] = tick
      }
    }
    guard !lastSeen.isEmpty else { return }
    let expired = lastSeen.compactMap { id, seen in
      tick &- seen > Self.retentionSnapshots ? id : nil
    }
    if !expired.isEmpty {
      store.remove(expired)
      for id in expired { lastSeen.removeValue(forKey: id) }
    }
  }

  func removeAll() {
    store.remove(lastSeen.keys)
    lastSeen.removeAll()
  }

  var publishedCount: Int { lastSeen.count }

  private static func copyImage(
    _ handle: OpaquePointer, _ imageId: UInt32, _ generation: UInt64
  ) -> FrameImage? {
    var image = LabanKittyImage()
    guard laban_session_kitty_image_copy(handle, imageId, generation, &image) == 0,
      let rgba = image.rgba
    else { return nil }
    defer { laban_kitty_image_free(&image) }
    let byteCount = Int(image.width) * Int(image.height) * 4
    return FrameImage(
      width: Int(image.width), height: Int(image.height),
      rgba: Data(bytes: rgba, count: byteCount))
  }
}
