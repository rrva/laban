import Dispatch
import Foundation

extension HeadlessDebugRuntime {
  public func artifactSnapshot() -> DebugResponse {
    let screenshot = withRuntimeLock { () -> ArtifactSnapshotScreenshot in
      let frame = currentFrame
      let start = DispatchTime.now()
      let pngData = surface.pngData
      timing.screenshotMs =
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
      if pngData != nil {
        screenshotCount += 1
      }
      return ArtifactSnapshotScreenshot(
        frame: frame,
        data: pngData,
        width: surface.width,
        height: surface.height
      )
    }

    let snapshotsRoot = artifactsURL.appendingPathComponent("snapshots", isDirectory: true)
    let writer = DebugArtifactSnapshotWriter(
      runId: runId,
      frame: screenshot.frame,
      snapshotsRoot: snapshotsRoot
    )
    let files = artifactSnapshotFiles(
      screenshot: screenshot,
      snapshotDirectory: writer.snapshotDirectory
    )

    do {
      let result = try writer.write(files: files)
      withRuntimeLock {
        appendEvent(
          EventEntry(
            kind: "snapshot.written",
            frame: screenshot.frame,
            path: result.manifestURL.path))
      }
      return jsonEncode(
        SnapshotResultResponse(path: result.manifestURL.path, frame: screenshot.frame))
    } catch ArtifactSnapshotWriteError.createDirectory(let error) {
      withRuntimeLock {
        appendError(kind: "snapshot.artifact", message: "failed to create snapshot dir: \(error)")
      }
      return jsonError("failed to create snapshot dir: \(error)", status: 500)
    } catch ArtifactSnapshotWriteError.write(let error) {
      withRuntimeLock {
        appendError(kind: "snapshot.artifact", message: "failed to write snapshot: \(error)")
      }
      return jsonError("failed to write snapshot: \(error)", status: 500)
    } catch {
      withRuntimeLock {
        appendError(kind: "snapshot.artifact", message: "failed to write snapshot: \(error)")
      }
      return jsonError("failed to write snapshot: \(error)", status: 500)
    }
  }

  private func artifactSnapshotFiles(
    screenshot: ArtifactSnapshotScreenshot,
    snapshotDirectory: URL
  ) -> [String: Data] {
    var files: [String: Data] = [
      "state.json": state().body,
      "sessions.json": sessions().body,
      "render.json": renderState().body,
      "frame-commands.json": frameCommands(query: ["source": "all", "limit": "2000"]).body,
      "render-trace.json": renderTrace(Data("{}".utf8)).body,
      "events.json": events(since: 0).body,
      "input-log.json": inputLogResponse(since: 0).body,
      "terminal-log.json": terminalLogResponse(query: [:]).body,
      "errors.json": errors(since: 0).body,
      "timing.json": timingResponse().body,
      "metrics.json": metricsResponse().body,
    ]

    if let data = screenshot.data {
      files["screenshot.png"] = data
      files["screenshot.json"] =
        jsonEncode(
          ScreenshotResult(
            path: snapshotDirectory.appendingPathComponent("screenshot.png").path,
            width: screenshot.width,
            height: screenshot.height,
            frame: screenshot.frame,
            target: "window"
          )
        ).body
    }

    return files
  }

  private struct ArtifactSnapshotScreenshot {
    var frame: Int
    var data: Data?
    var width: Int
    var height: Int
  }
}
