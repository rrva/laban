import CoreGraphics
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

extension HeadlessDebugRuntime {
  public func fixtureControl(_ data: Data) -> DebugResponse {
    guard let request = try? JSONDecoder().decode(FixtureControlRequest.self, from: data) else {
      withRuntimeLock {
        appendError(kind: "fixture.invalid", message: "invalid fixture control request")
      }
      return jsonError("invalid fixture control request")
    }

    return withRuntimeLock {
      switch request.action {
      case "load":
        return loadFixtureUnlocked(request)
      case "restart":
        return restartFixtureUnlocked(request)
      case "step":
        return stepFixtureUnlocked(request)
      default:
        appendError(
          kind: "fixture.unsupported",
          message: "unsupported fixture action \(request.action)")
        return fixtureResult(
          ok: false,
          action: request.action,
          error: "unsupported fixture action \(request.action)")
      }
    }
  }

  private func loadFixtureUnlocked(_ request: FixtureControlRequest) -> DebugResponse {
    guard let rawPath = request.path else {
      appendError(kind: "fixture.load", message: "fixture load requires path")
      return fixtureResult(ok: false, action: request.action, error: "fixture load requires path")
    }

    let url: URL
    do {
      url = try resolveFixtureURL(rawPath)
    } catch {
      appendError(kind: "fixture.load", message: "rejected fixture path: \(error)")
      return fixtureResult(
        ok: false,
        action: request.action,
        error: "rejected fixture path: \(error)"
      )
    }

    do {
      let runner = try FixtureRunner.load(from: url)
      try resetFixtureModelUnlocked(runner: runner)
      fixtureURL = url
      fixtureRunner = runner
      fixtureStepIndex = 0
      mode = "fixture"
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "fixture.loaded", path: url.path))
      return fixtureResult(ok: true, action: request.action)
    } catch {
      appendError(kind: "fixture.load", message: "failed to load fixture: \(error)")
      return fixtureResult(
        ok: false,
        action: request.action,
        error: "failed to load fixture: \(error)"
      )
    }
  }

  private func restartFixtureUnlocked(_ request: FixtureControlRequest) -> DebugResponse {
    guard let runner = fixtureRunner else {
      appendError(kind: "fixture.restart", message: "no fixture is loaded")
      return fixtureResult(ok: false, action: request.action, error: "no fixture is loaded")
    }

    do {
      try resetFixtureModelUnlocked(runner: runner)
      fixtureStepIndex = 0
      mode = "fixture"
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "fixture.restarted", path: fixtureURL?.path))
      return fixtureResult(ok: true, action: request.action)
    } catch {
      appendError(kind: "fixture.restart", message: "failed to restart fixture: \(error)")
      return fixtureResult(
        ok: false,
        action: request.action,
        error: "failed to restart fixture: \(error)")
    }
  }

  private func stepFixtureUnlocked(_ request: FixtureControlRequest) -> DebugResponse {
    guard fixtureRunner != nil else {
      appendError(kind: "fixture.step", message: "no fixture is loaded")
      return fixtureResult(ok: false, action: request.action, error: "no fixture is loaded")
    }

    let count = max(request.count ?? 1, 1)
    do {
      try applyFixtureStepsUnlocked(count: count)
      appendEvent(EventEntry(kind: "fixture.stepped", action: "step"))
      return fixtureResult(ok: true, action: request.action)
    } catch {
      appendError(kind: "fixture.step", message: "failed to step fixture: \(error)")
      return fixtureResult(
        ok: false,
        action: request.action,
        error: "failed to step fixture: \(error)"
      )
    }
  }

  private func resolveFixtureURL(_ path: String) throws -> URL {
    try DebugFixtureResolver.resolve(path, root: fixtureRootURL)
  }

  private func resetFixtureModelUnlocked(runner: FixtureRunner) throws {
    model.closeAllSessions()
    sessionMode = .fixture

    var size = LabanTerminalSize()
    size.rows = Int32(runner.fixture.initialSize.rows)
    size.cols = Int32(runner.fixture.initialSize.cols)

    model = try AppModel(
      initialSize: size,
      sessionFactory: { [weak self] size in
        let session = try Session.fixture(size: size)
        session.captureSink = self?.captureRecorder
        return session
      })
    model.captureSink = captureRecorder
    surfaceController = TerminalSurfaceController(
      model: model,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      sidebarWidth: CGFloat(sidebarWidth),
      sidebarCellWidth: CGFloat(cellWidth),
      sidebarCellHeight: CGFloat(cellHeight),
      captureSink: captureRecorder)
    selectionBySession.removeAll()
    debugClipboard = ""
    lastCopyText = nil
    lastPasteText = nil
    lastPasteUsedBracketedPaste = nil
    lastPasteIgnoredNonText = nil

    windowWidth = sidebarWidth + runner.fixture.initialSize.cols * cellWidth
    windowHeight = runner.fixture.initialSize.rows * cellHeight
    surface = BitmapSurface(width: max(windowWidth, 1), height: max(windowHeight, 1))
    renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
    rebuildRendererBackendUnlocked()
  }

  private func applyFixtureStepsUnlocked(count: Int) throws {
    guard let runner = fixtureRunner, let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else { return }

    let steps = runner.fixture.steps
    guard fixtureStepIndex < steps.count else {
      renderFrameUnlocked()
      return
    }

    let end = min(fixtureStepIndex + count, steps.count)
    while fixtureStepIndex < end {
      let step = steps[fixtureStepIndex]
      fixtureStepIndex += 1
      switch step {
      case .setTitle(let title):
        let bytes = Array("\u{1B}]0;\(title)\u{07}".utf8)
        _ = session.write(bytes)
        _ = session.poll()
        appendTerminalLog(sessionId: session.id, direction: "output", bytes: bytes)
        renderFrameUnlocked()

      case .writeBytes(let encoding, let data):
        guard encoding == "utf8" else { throw FixtureError.unsupportedEncoding(encoding) }
        let bytes = Array(data.utf8)
        _ = session.write(bytes)
        _ = session.poll()
        appendTerminalLog(sessionId: session.id, direction: "output", bytes: bytes)
        renderFrameUnlocked()

      case .waitFrames(let frameCount):
        for _ in 0..<frameCount {
          _ = session.poll()
          renderFrameUnlocked()
        }
      }
    }
  }

  private func fixtureResult(ok: Bool, action: String, error: String? = nil) -> DebugResponse {
    let active = model.activeTab
    return jsonEncode(
      FixtureControlResponse(
        ok: ok,
        action: action,
        frame: currentFrame,
        fixtureName: fixtureRunner?.fixture.name,
        fixturePath: fixtureURL?.path,
        stepIndex: fixtureStepIndex,
        stepCount: fixtureRunner?.fixture.steps.count ?? 0,
        activeTabId: active?.id,
        activeSessionId: active?.sessionId,
        error: error
      ),
      status: ok ? 200 : 400
    )
  }
}
