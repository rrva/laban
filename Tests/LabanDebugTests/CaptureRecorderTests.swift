import Darwin
import Foundation
import LabanCore
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

  private func timelineEvents(_ url: URL) throws -> [CaptureTimelineEvent] {
    let decoder = JSONDecoder()
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map { try decoder.decode(CaptureTimelineEvent.self, from: Data(String($0).utf8)) }
  }
}
