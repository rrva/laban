import Foundation

extension HeadlessDebugRuntime {
  public func screenshotBytes() throws -> (data: Data, frame: Int, width: Int, height: Int) {
    try withRuntimeLock {
      let start = monotonicNow()
      guard let pngData = rendererBackend.pngData else { throw DebugServerError.encodingFailed }
      timing.screenshotMs = elapsedMs(since: start)
      screenshotCount += 1
      return (pngData, currentFrame, rendererBackend.surfaceWidth, rendererBackend.surfaceHeight)
    }
  }

  public func writeScreenshotArtifact() -> DebugResponse {
    withRuntimeLock {
      let start = monotonicNow()
      guard let pngData = rendererBackend.pngData else {
        appendError(kind: "screenshot.encoding", message: "PNG encoding failed")
        return jsonError("PNG encoding failed", status: 500)
      }
      timing.screenshotMs = elapsedMs(since: start)
      screenshotCount += 1
      let screenshotDirectory = artifactsURL.appendingPathComponent("screenshots")
      do {
        try FileManager.default.createDirectory(
          at: screenshotDirectory,
          withIntermediateDirectories: true)
      } catch {
        appendError(
          kind: "screenshot.artifact",
          message: "failed to create screenshots dir: \(error)"
        )
        return jsonError("failed to create screenshots dir: \(error)", status: 500)
      }

      let fileName = String(format: "frame-%06d.png", currentFrame)
      let fileURL = screenshotDirectory.appendingPathComponent(fileName)
      do {
        try pngData.write(to: fileURL)
      } catch {
        appendError(kind: "screenshot.artifact", message: "failed to write screenshot: \(error)")
        return jsonError("failed to write screenshot: \(error)", status: 500)
      }

      appendEvent(EventEntry(kind: "screenshot.captured", frame: currentFrame, path: fileURL.path))
      captureRecorder?.recordScreenshot(frame: currentFrame, data: pngData)
      return jsonEncode(
        ScreenshotResult(
          path: fileURL.path,
          width: rendererBackend.surfaceWidth,
          height: rendererBackend.surfaceHeight,
          frame: currentFrame,
          target: "window"
        ))
    }
  }
}
