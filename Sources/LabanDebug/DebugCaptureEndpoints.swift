import Foundation

extension HeadlessDebugRuntime {
  public func captureStatus() -> DebugResponse {
    withRuntimeLock {
      if let recorder = captureRecorder {
        return jsonEncode(
          CaptureStatusResponse(
            active: true,
            runId: recorder.runId,
            directory: recorder.directoryURL.path,
            manifestPath: nil,
            screenshots: recorder.screenshots.rawValue
          ))
      }
      return jsonEncode(
        CaptureStatusResponse(
          active: false,
          runId: lastCaptureRunId,
          directory: lastCaptureDirectory,
          manifestPath: lastCaptureManifestPath,
          screenshots: nil
        ))
    }
  }

  public func startCapture(_ data: Data) -> DebugResponse {
    withRuntimeLock {
      if let recorder = captureRecorder {
        return jsonEncode(
          CaptureStartResponse(
            active: true,
            alreadyActive: true,
            runId: recorder.runId,
            directory: recorder.directoryURL.path,
            screenshots: recorder.screenshots.rawValue
          ),
          status: 409
        )
      }

      let body = data.isEmpty ? Data("{}".utf8) : data
      let request =
        (try? JSONDecoder().decode(CaptureStartRequest.self, from: body))
        ?? CaptureStartRequest()
      let policy = Self.capturePolicy(from: request.screenshots)
      let name = request.name ?? CaptureRecorder.makeRunId(name: nil)
      do {
        try CaptureRecorder.validateCaptureName(name)
        let recorder = try CaptureRecorder(
          artifactRoot: artifactsURL.appendingPathComponent("captures", isDirectory: true),
          name: name,
          screenshots: policy,
          executable: "laban-agent"
        )
        captureRecorder = recorder
        surfaceController.captureSink = recorder
        model.captureSink = recorder
        lastCaptureRunId = recorder.runId
        lastCaptureDirectory = recorder.directoryURL.path
        lastCaptureManifestPath = nil
        model.recordExistingStateForCapture()
        return jsonEncode(
          CaptureStartResponse(
            active: true,
            alreadyActive: false,
            runId: recorder.runId,
            directory: recorder.directoryURL.path,
            screenshots: recorder.screenshots.rawValue
          ))
      } catch {
        return jsonError("capture start failed: \(error)", status: 400)
      }
    }
  }

  public func stopCapture() -> DebugResponse {
    withRuntimeLock {
      do {
        guard let result = try finishCaptureUnlocked(interrupted: false) else {
          if let manifest = lastCaptureManifestPath {
            return jsonEncode(
              CaptureStopResponse(
                active: false,
                runId: lastCaptureRunId,
                directory: lastCaptureDirectory,
                manifestPath: manifest
              ))
          }
          return jsonError("capture is not active", status: 400)
        }
        return jsonEncode(
          CaptureStopResponse(
            active: false,
            runId: result.runId,
            directory: result.directory,
            manifestPath: result.manifestPath
          ))
      } catch {
        return jsonError("capture stop failed: \(error)", status: 500)
      }
    }
  }

  public func shutdown(interrupted: Bool = true) {
    withRuntimeLock {
      _ = try? finishCaptureUnlocked(interrupted: interrupted)
      shutdownTerminalClientUnlocked()
      model.closeAllSessions()
    }
  }

  public func captureSnapshot() -> DebugResponse {
    withRuntimeLock {
      guard let recorder = captureRecorder else {
        return jsonError("capture is not active", status: 400)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let serializer = DebugFrameCommandSerializer(cellWidth: cellWidth, cellHeight: cellHeight)
      let frameCommandBody =
        FrameCommandsResponse(
          frame: currentFrame,
          backend: "software",
          commands: lastFrameCommands.enumerated().map {
            serializer.listCommand($0.element, index: $0.offset, includeText: true)
          },
          truncated: false
        )
      var files: [String: Data] = [
        "state.json": stateUnlocked().body,
        "events.json": (try? encoder.encode(logs.eventsResponse(since: 0))) ?? Data(),
        "input-log.json": (try? encoder.encode(logs.inputLogResponse(since: 0))) ?? Data(),
        "frame-commands.json": (try? encoder.encode(frameCommandBody)) ?? Data(),
      ]
      if let png = surface.pngData {
        files["screenshot.png"] = png
      }
      do {
        let relativePath = try recorder.writeSnapshotBundle(frame: currentFrame, files: files)
        return jsonEncode(["path": recorder.directoryURL.appendingPathComponent(relativePath).path])
      } catch {
        return jsonError("capture snapshot failed: \(error)", status: 500)
      }
    }
  }

  private func finishCaptureUnlocked(
    interrupted: Bool
  ) throws -> (runId: String, directory: String, manifestPath: String)? {
    guard let recorder = captureRecorder else {
      return nil
    }

    let finalPNG: Data?
    if recorder.screenshots == .none {
      finalPNG = nil
    } else {
      finalPNG = surface.pngData
    }
    let manifest = try recorder.finish(
      interrupted: interrupted,
      finalScreenshot: finalPNG,
      frame: currentFrame
    )
    captureRecorder = nil
    surfaceController.captureSink = nil
    model.captureSink = nil
    lastCaptureManifestPath = manifest.path
    lastCaptureRunId = recorder.runId
    lastCaptureDirectory = recorder.directoryURL.path
    return (recorder.runId, recorder.directoryURL.path, manifest.path)
  }

  private static func capturePolicy(from raw: String?) -> CaptureScreenshotPolicy {
    switch raw?.lowercased() {
    case "final": return .final
    case "all": return .all
    case "none": return .none
    default: return .marked
    }
  }
}
