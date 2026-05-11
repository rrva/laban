import Foundation

struct ArtifactSnapshotWriteResult {
  var manifestURL: URL
  var snapshotDirectory: URL
}

enum ArtifactSnapshotWriteError: Error {
  case createDirectory(Error)
  case write(Error)
}

struct DebugArtifactSnapshotWriter {
  var runId: String
  var frame: Int
  var snapshotsRoot: URL
  var createdAt: () -> Date = Date.init

  var snapshotDirectory: URL {
    snapshotsRoot.appendingPathComponent(
      String(format: "snapshot-%06d", frame),
      isDirectory: true
    )
  }

  func write(files: [String: Data]) throws -> ArtifactSnapshotWriteResult {
    let snapshotDir = snapshotDirectory

    do {
      try FileManager.default.createDirectory(
        at: snapshotDir,
        withIntermediateDirectories: true
      )
    } catch {
      throw ArtifactSnapshotWriteError.createDirectory(error)
    }

    var manifestFiles: [ArtifactSnapshotFile] = []
    do {
      for (name, data) in files.sorted(by: { $0.key < $1.key }) {
        let url = snapshotDir.appendingPathComponent(name)
        try data.write(to: url)
        manifestFiles.append(ArtifactSnapshotFile(name: name, path: url.path))
      }

      let manifestURL = snapshotDir.appendingPathComponent("manifest.json")
      let manifest = ArtifactSnapshotManifest(
        kind: "laban-debug-snapshot",
        runId: runId,
        frame: frame,
        createdAt: createdAt(),
        files: manifestFiles
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(manifest).write(to: manifestURL)

      return ArtifactSnapshotWriteResult(
        manifestURL: manifestURL,
        snapshotDirectory: snapshotDir
      )
    } catch {
      throw ArtifactSnapshotWriteError.write(error)
    }
  }
}
