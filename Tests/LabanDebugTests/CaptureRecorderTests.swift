import CoreGraphics
import Darwin
import Foundation
import LabanCore
import LabanRenderer
import XCTest

@testable import LabanDebug

final class CaptureRecorderTests: XCTestCase {
  func testMonotonicSequenceNumbersAndByteSidecars() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "recorder")

    let first = Data("hello".utf8)
    let second = Data(" world".utf8)
    _ = first.withUnsafeBytes {
      recorder.recordBytes(
        direction: .ptyOutput, sessionId: "session-1", frame: 1, bytes: $0, preview: nil)
    }
    _ = second.withUnsafeBytes {
      recorder.recordBytes(
        direction: .ptyOutput, sessionId: "session-1", frame: 1, bytes: $0, preview: nil)
    }
    recorder.record(CaptureTimelineEvent(kind: .frameBegin, frame: 1))
    let manifest = try recorder.finish()

    XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    let streamURL = root.appendingPathComponent("recorder/streams/pty-output.bin")
    XCTAssertEqual(try Data(contentsOf: streamURL), Data("hello world".utf8))

    let events = try timelineEvents(root.appendingPathComponent("recorder/timeline.ndjson"))
    XCTAssertEqual(events.map(\.seq), Array(0..<events.count))
    XCTAssertTrue(events.contains { $0.kind == CaptureEventKind.ptyOutput.rawValue })
  }

  func testByteOffsetsAndHashesAreRecorded() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "offsets")
    let bytes = Data([0x1B, 0x5B, 0x48])
    let ref = bytes.withUnsafeBytes {
      recorder.recordBytes(
        direction: .ptyInput, sessionId: "session-1", frame: 3, bytes: $0, preview: nil)
    }
    _ = try recorder.finish()

    XCTAssertEqual(ref?.offset, 0)
    XCTAssertEqual(ref?.length, 3)
    XCTAssertEqual(ref?.sha256, CaptureHash.sha256(bytes))
    let events = try timelineEvents(root.appendingPathComponent("offsets/timeline.ndjson"))
    let input = events.first { $0.kind == CaptureEventKind.ptyInput.rawValue }
    XCTAssertEqual(input?.offset, 0)
    XCTAssertEqual(input?.length, 3)
    XCTAssertEqual(input?.sha256, CaptureHash.sha256(bytes))
  }

  func testManifestStreamMetadataDoesNotRequireRereadingSidecar() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "stream-manifest")
    let bytes = Data("large stream metadata source".utf8)
    _ = bytes.withUnsafeBytes {
      recorder.recordBytes(
        direction: .ptyOutput, sessionId: "session-1", frame: 4, bytes: $0, preview: nil)
    }

    let streamURL = root.appendingPathComponent("stream-manifest/streams/pty-output.bin")
    chmod(streamURL.path, S_IWUSR)
    let manifest = try recorder.finish()

    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
    let streams = obj["streams"] as! [String: Any]
    let ptyOutput = streams["ptyOutput"] as! [String: Any]
    XCTAssertEqual(ptyOutput["bytes"] as? Int, bytes.count)
    XCTAssertEqual(ptyOutput["sha256"] as? String, CaptureHash.sha256(bytes))
  }

  func testFinalizeIsAtomicAndWritesManifest() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "finalize")
    let captureDir = root.appendingPathComponent("finalize")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: captureDir.appendingPathComponent("manifest.json.tmp").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: captureDir.appendingPathComponent("manifest.json").path))

    let manifest = try recorder.finish()
    XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: captureDir.appendingPathComponent("manifest.json.tmp").path))

    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
    XCTAssertEqual(obj["kind"] as? String, "laban-capture")
    XCTAssertNotNil(obj["finishedAt"])
  }

  func testInterruptedFinishIsRecoverable() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "interrupted")
    let bytes = Data("partial".utf8)
    _ = bytes.withUnsafeBytes {
      recorder.recordBytes(
        direction: .ptyOutput, sessionId: "session-1", frame: 0, bytes: $0, preview: nil)
    }
    let manifest = try recorder.finish(interrupted: true)
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
    XCTAssertEqual(obj["interrupted"] as? Bool, true)
    XCTAssertGreaterThan(
      try timelineEvents(root.appendingPathComponent("interrupted/timeline.ndjson")).count, 0)
  }

  func testPrivateFilePermissionsWhereSupported() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "perms")
    let manifest = try recorder.finish()

    var st = stat()
    XCTAssertEqual(stat(manifest.path, &st), 0)
    let mode = st.st_mode & S_IRWXU | st.st_mode & S_IRWXG | st.st_mode & S_IRWXO
    XCTAssertEqual(mode & S_IRWXG, 0)
    XCTAssertEqual(mode & S_IRWXO, 0)
  }

  func testInitRejectsDotAndDotDotNames() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try CaptureRecorder(artifactRoot: root, name: ".")) { error in
      XCTAssertEqual(error as? CaptureRecorderError, .outsideArtifactRoot)
    }
    XCTAssertThrowsError(try CaptureRecorder(artifactRoot: root, name: "..")) { error in
      XCTAssertEqual(error as? CaptureRecorderError, .outsideArtifactRoot)
    }
  }

  func testInitAcceptsNormalNameAndCreatesDirectory() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "normal-name")
    _ = try recorder.finish()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("normal-name").path))
  }

  func testWriteSnapshotBundleRejectsPathTraversalKeys() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "snapshot-traversal")

    XCTAssertThrowsError(
      try recorder.writeSnapshotBundle(frame: 1, files: ["../evil": Data("x".utf8)])
    ) { error in
      XCTAssertEqual(error as? CaptureRecorderError, .outsideArtifactRoot)
    }
    XCTAssertThrowsError(
      try recorder.writeSnapshotBundle(frame: 1, files: ["a/b": Data("x".utf8)])
    ) { error in
      XCTAssertEqual(error as? CaptureRecorderError, .outsideArtifactRoot)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("evil").path),
      "traversal key must not escape the capture directory")
  }

  func testWriteSnapshotBundleAcceptsNormalKeys() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "snapshot-normal")

    let relDir = try recorder.writeSnapshotBundle(
      frame: 2, files: ["a.txt": Data("x".utf8), "b.json": Data("{}".utf8)])
    _ = try recorder.finish()

    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("snapshot-normal/\(relDir)/a.txt").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("snapshot-normal/\(relDir)/b.json").path))
  }

  func testCompositeGrabWritesWindowSidecarAndSkipsPixelReadback() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let composite = try CaptureRecorder(
      artifactRoot: root, name: "composite", screenshots: .composite)
    XCTAssertFalse(composite.needsRenderedPixelReadback)

    let rel = composite.recordCompositeGrab(sequence: 1, frame: 7, data: Data("png-bytes".utf8))
    XCTAssertEqual(rel, "window/grab-000001.png")
    _ = try composite.finish()

    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("composite/window/grab-000001.png").path))
    let events = try timelineEvents(root.appendingPathComponent("composite/timeline.ndjson"))
    let grab = events.first { $0.kind == CaptureEventKind.screenshotCaptured.rawValue }
    XCTAssertEqual(grab?.path, "window/grab-000001.png")
    XCTAssertEqual(grab?.frame, 7)

    let inApp = try CaptureRecorder(artifactRoot: root, name: "in-app", screenshots: .final)
    XCTAssertTrue(inApp.needsRenderedPixelReadback)
    _ = try inApp.finish()
  }

  func testSchemaExamplesAreValidJSON() throws {
    let manifest = """
      {"schemaVersion":1,"kind":"laban-capture","runId":"r","createdAt":"now","app":{"gitSha":"unknown","buildConfiguration":"debug","executable":"x"},"privacy":{"containsTerminalBytes":true,"containsScreenshots":false,"redaction":"none"},"timeline":{"path":"timeline.ndjson","events":0},"streams":{},"frames":{"count":0}}
      """
    let event = #"{"seq":0,"timeNs":1,"kind":"capture.started"}"#
    let report =
      #"{"schemaVersion":1,"captureRunId":"r","terminalReplay":"passed","rendererReplay":"passed","framesCompared":0,"mismatches":[]}"#
    for json in [manifest, event, report] {
      XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }
  }

  private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-capture-recorder-\(UUID().uuidString)")
  }

  /// A capture frame's PNG is deflated on a background queue, so the timeline
  /// event is written later than the frame was rendered. The caller stamps the
  /// two ordering keys in the frame loop and passes them through; without that,
  /// a deferred encode would place the frame after events that actually came
  /// later, and `timeNs` would describe the deflate rather than the frame.
  func testRenderedFrameKeepsCallerSuppliedOrderingKeys() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "ordering")

    let seq = recorder.nextSequence()
    let renderedAt: UInt64 = 12_345_678
    // Something else reaches the timeline before the deferred encode lands.
    recorder.record(CaptureTimelineEvent(kind: .frameRendered, frame: 99))
    recorder.recordRenderedFrame(
      frame: 7, pngData: nil, width: 4, height: 2, scale: 1, backend: "vectorGlyph",
      seq: seq, timeNs: renderedAt)
    _ = try recorder.finish()

    let events = try timelineEvents(root.appendingPathComponent("ordering/timeline.ndjson"))
    let deferred = try XCTUnwrap(events.first { $0.frame == 7 })
    XCTAssertEqual(deferred.seq, seq)
    XCTAssertEqual(deferred.timeNs, renderedAt)
    let later = try XCTUnwrap(events.first { $0.frame == 99 })
    XCTAssertGreaterThan(later.seq, deferred.seq, "the reserved seq must still sort first")
  }

  /// Defaulted ordering keys keep the original stamp-at-write behavior for
  /// every caller that still records inline.
  func testRenderedFrameStampsOrderingKeysWhenCallerOmitsThem() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try CaptureRecorder(artifactRoot: root, name: "defaults")
    recorder.recordRenderedFrame(
      frame: 3, pngData: nil, width: 4, height: 2, scale: 1, backend: "software")
    _ = try recorder.finish()

    let events = try timelineEvents(root.appendingPathComponent("defaults/timeline.ndjson"))
    let event = try XCTUnwrap(events.first { $0.frame == 3 })
    XCTAssertGreaterThanOrEqual(event.seq, 0)
    XCTAssertGreaterThan(event.timeNs, 0)
  }

  private func timelineEvents(_ url: URL) throws -> [CaptureTimelineEvent] {
    let decoder = JSONDecoder()
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map { try decoder.decode(CaptureTimelineEvent.self, from: Data(String($0).utf8)) }
  }

  // Capture replay must round-trip text attributes so SGR styling shows
  // up identically when the recorded session is replayed offline.
  func testFrameCommandCodecRoundTripsTextAttributes() throws {
    let original: [FrameCommand] = [
      .glyphRun(
        origin: CGPoint(x: 4, y: 8), text: "X",
        foreground: 0xAABB_CCFF, background: 0x1122_33FF,
        attributes: [.bold, .underline, .italic],
        source: .terminal),
      .glyphRun(
        origin: .zero, text: "Y",
        foreground: 0xFFFF_FFFF, background: 0x0000_0000,
        attributes: [],
        source: .terminal),
    ]
    let captured = LabanCore.FrameCommandCaptureCodec.serialized(original)
    let json = try LabanCore.FrameCommandCaptureCodec.encoder.encode(captured)
    let decoded = try JSONDecoder().decode([LabanCore.CapturedFrameCommand].self, from: json)
    let restored: [FrameCommand] = LabanCore.FrameCommandCaptureCodec.commands(from: decoded)
    XCTAssertEqual(restored.count, 2)
    if case .glyphRun(_, let text, _, _, let attrs, _, _, _, _, _, _, _, _) = restored[0] {
      XCTAssertEqual(text, "X")
      XCTAssertEqual(attrs, [.bold, .italic, .underline])
    } else {
      XCTFail("expected glyphRun with attributes")
    }
    if case .glyphRun(_, _, _, _, let attrs, _, _, _, _, _, _, _, _) = restored[1] {
      XCTAssertEqual(attrs, [])
    } else {
      XCTFail("expected glyphRun")
    }
    let jsonText = String(decoding: json, as: UTF8.self)
    let expectedAttrs = "\"attributes\":[\"bold\",\"italic\",\"underline\"]"
    XCTAssertTrue(
      jsonText.contains(expectedAttrs),
      "captured JSON should serialize attributes by name for diffability")
  }
}
