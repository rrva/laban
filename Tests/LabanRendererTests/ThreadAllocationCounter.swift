import Darwin
import Foundation

/// Counts heap allocations made by one thread, via libmalloc's `malloc_logger`
/// hook (the hook MallocStackLogging uses). The hook sees every zone
/// allocation process-wide; it keeps only the thread that started counting,
/// so Metal's and XCTest's own threads do not pollute the number. The hook
/// itself never allocates.
///
/// Only one measurement may be active at a time; it is not reentrant.
enum ThreadAllocationCounter {
  struct Tally: Equatable {
    var allocations = 0
    var bytes = 0
    /// Allocations of at least `largeAllocationBytes`: buffers sized by the
    /// frame's content rather than fixed bookkeeping.
    var largeAllocations = 0
  }

  struct CallSite {
    var frames: String
    var allocations: Int
    var bytes: Int
  }

  static let largeAllocationBytes = 16 * 1024

  private typealias Logger =
    @convention(c) (
      UInt32, UInt, UInt, UInt, UInt, UInt32
    ) -> Void

  // libmalloc's `malloc_logger` type flags.
  private static let typeAllocate: UInt32 = 2
  private static let typeDeallocate: UInt32 = 4

  private static let stackDepth = 16
  private static let stackCapacity = 4096

  nonisolated(unsafe) private static var thread: pthread_t?
  nonisolated(unsafe) private static var tally = Tally()
  nonisolated(unsafe) private static var stacks: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
  nonisolated(unsafe) private static var stackSizes: UnsafeMutablePointer<Int>?
  nonisolated(unsafe) private static var stackCount = 0

  private static let loggerSlot: UnsafeMutablePointer<Logger?>? = {
    // RTLD_DEFAULT
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
      return nil
    }
    return symbol.assumingMemoryBound(to: Logger?.self)
  }()

  static var isAvailable: Bool { loggerSlot != nil }

  /// Runs `body` and returns what the calling thread allocated while it ran,
  /// or nil when the hook is unavailable or already taken. A realloc counts
  /// as one allocation of its new size.
  static func measure(_ body: () throws -> Void) rethrows -> Tally? {
    guard let loggerSlot, loggerSlot.pointee == nil else { return nil }
    tally = Tally()
    thread = pthread_self()
    loggerSlot.pointee = { type, _, arg2, arg3, _, _ in
      guard type & ThreadAllocationCounter.typeAllocate != 0,
        let owner = ThreadAllocationCounter.thread,
        pthread_equal(owner, pthread_self()) != 0
      else { return }
      // malloc/calloc pass the size in arg2 (zone in arg1); realloc, flagged
      // allocate|deallocate, passes the old pointer in arg2 and new size in arg3.
      let size = Int(
        bitPattern: type & ThreadAllocationCounter.typeDeallocate != 0 ? arg3 : arg2)
      ThreadAllocationCounter.tally.allocations += 1
      ThreadAllocationCounter.tally.bytes += size
      if size >= ThreadAllocationCounter.largeAllocationBytes {
        ThreadAllocationCounter.tally.largeAllocations += 1
      }
      if let stacks = ThreadAllocationCounter.stacks,
        let sizes = ThreadAllocationCounter.stackSizes,
        ThreadAllocationCounter.stackCount < ThreadAllocationCounter.stackCapacity
      {
        let index = ThreadAllocationCounter.stackCount
        _ = backtrace(
          stacks + index * ThreadAllocationCounter.stackDepth,
          Int32(ThreadAllocationCounter.stackDepth))
        sizes[index] = size
        ThreadAllocationCounter.stackCount += 1
      }
    }
    defer {
      loggerSlot.pointee = nil
      thread = nil
    }
    try body()
    return tally
  }

  /// Runs `body` once and groups its allocations by call site: the first few
  /// frames outside libmalloc, as `symbol+offset`, largest total bytes first.
  /// Diagnostic only, for finding what a failing count is made of; offsets
  /// map to lines with `atos`.
  static func callSites(frameCount: Int = 4, _ body: () throws -> Void) rethrows -> [CallSite] {
    let storage = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(
      capacity: stackCapacity * stackDepth)
    storage.initialize(repeating: nil, count: stackCapacity * stackDepth)
    let sizes = UnsafeMutablePointer<Int>.allocate(capacity: stackCapacity)
    sizes.initialize(repeating: 0, count: stackCapacity)
    defer {
      storage.deallocate()
      sizes.deallocate()
    }
    stackCount = 0
    stacks = storage
    stackSizes = sizes
    defer {
      stacks = nil
      stackSizes = nil
    }
    _ = try measure(body)

    var sites: [String: CallSite] = [:]
    for index in 0..<stackCount {
      var frames: [String] = []
      for depth in 0..<stackDepth where frames.count < frameCount {
        guard let address = storage[index * stackDepth + depth] else { break }
        var info = Dl_info()
        guard dladdr(address, &info) != 0 else { continue }
        let image = info.dli_fname.map { String(cString: $0) } ?? "?"
        let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
        if image.contains("libsystem_malloc") || symbol.contains("ThreadAllocationCounter") {
          continue
        }
        let offset = info.dli_saddr.map { address - $0 } ?? 0
        frames.append("\(symbol)+\(offset)")
      }
      let key = frames.joined(separator: " <- ")
      var site = sites[key] ?? CallSite(frames: key, allocations: 0, bytes: 0)
      site.allocations += 1
      site.bytes += sizes[index]
      sites[key] = site
    }
    return sites.values.sorted { $0.bytes > $1.bytes }
  }
}
