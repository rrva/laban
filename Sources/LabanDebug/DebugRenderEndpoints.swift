import CoreText
import Foundation
import LabanTerminalCore

extension HeadlessDebugRuntime {
  public func atlas() -> DebugResponse {
    withRuntimeLock {
      let diagnostics = glyphDiagnosticsUnlocked()
      let cjk = fontAtlas.cjkFontDiagnostics
      return jsonEncode(
        AtlasResponse(
          font: CTFontCopyPostScriptName(fontAtlas.font) as String,
          fontSize: Double(fontAtlas.pointSize),
          cell: AtlasCellResponse(
            width: cellWidth,
            height: cellHeight,
            baseline: max(Int(ceil(fontAtlas.ascent)), 0)
          ),
          cjkFont: AtlasCJKFontResponse(
            font: cjk.selectedFontPostScriptName,
            family: cjk.selectedFamilyName,
            source: cjk.selectedSource,
            candidates: cjk.candidateFonts,
            fallbackOrder: cjk.fallbackOrder,
            glyphAvailable: cjk.glyphAvailable,
            glyphAdvance: Double(cjk.glyphAdvance),
            targetCellWidth: Double(cjk.targetCellWidth),
            scaleX: Double(cjk.scaleX)
          ),
          glyphs: AtlasGlyphsResponse(
            loaded: diagnostics.loaded,
            missing: diagnostics.missingCodepoints.count
          ),
          missingCodepoints: diagnostics.missingCodepoints,
          atlases: [],
          backend: "software",
          emojiRendering: emojiRenderingSettingsResponse()
        ))
    }
  }

  public func renderState() -> DebugResponse {
    withRuntimeLock {
      let terminalViewportWidth = max(windowWidth - sidebarWidth, 1)
      let status = rendererBackend.rendererStatus
      return jsonEncode(
        RenderResponse(
          frame: currentFrame,
          backend: status.effectiveRenderer,
          configuredRenderer: status.configuredRenderer,
          effectiveRenderer: status.effectiveRenderer,
          fallbackReason: status.fallbackReason,
          rasterFallbackGlyphs: status.rasterFallbackGlyphs,
          vectorSubpixelLayout: status.vectorSubpixelLayout,
          surface: SurfaceResponse(
            width: rendererBackend.surfaceWidth,
            height: rendererBackend.surfaceHeight,
            scale: Double(rendererBackend.surfaceScale)),
          terminalViewport: RectResponse(
            x: sidebarWidth, y: 0, width: terminalViewportWidth, height: windowHeight),
          cell: CellSizeResponse(width: cellWidth, height: cellHeight),
          damage: [RectResponse(x: 0, y: 0, width: surface.width, height: surface.height)],
          lastDraw: DrawStatsResponse(
            cells: lastDrawStats.cells,
            glyphs: lastDrawStats.glyphs,
            backgroundRects: lastDrawStats.backgroundRects,
            images: lastDrawStats.images,
            cursor: lastDrawStats.cursor
          ),
          emojiRendering: emojiRenderingSettingsResponse()
        ))
    }
  }

  public func frameCommands(query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      let sourceFilter = query["source"] ?? "all"
      let limit = min(query["limit"].flatMap { Int($0) } ?? 500, 2000)
      let includeText = query["includeText"] != "false"
      let serializer = DebugFrameCommandSerializer(cellWidth: cellWidth, cellHeight: cellHeight)

      var result: [FrameCommandResponse] = []
      var truncated = false

      for (index, command) in lastFrameCommands.enumerated() {
        let response = serializer.listCommand(command, index: index, includeText: includeText)
        if sourceFilter != "all" && response.source != sourceFilter { continue }
        if result.count >= limit {
          truncated = true
          break
        }
        result.append(response)
      }

      return jsonEncode(
        FrameCommandsResponse(
          frame: currentFrame,
          backend: "software",
          commands: result,
          truncated: truncated
        ))
    }
  }

  public func renderTrace(_ data: Data) -> DebugResponse {
    withRuntimeLock {
      let body = data.isEmpty ? Data("{}".utf8) : data
      let request =
        (try? JSONDecoder().decode(RenderTraceRequest.self, from: body)) ?? RenderTraceRequest()
      let limit = min(request.limit ?? 500, 2000)
      let frame = currentFrame

      let hasActiveTab = model.activeTab != nil
      var terminalSnapshot: DebugRenderTraceTerminalSnapshot? = nil
      if let tab = model.activeTab,
        let session = model.session(forTab: tab.id),
        let snapshot = session.snapshot()
      {
        defer { laban_snapshot_destroy(snapshot) }
        terminalSnapshot = DebugRenderTraceTerminalSnapshot(
          sessionId: tab.sessionId,
          rows: Int(snapshot.pointee.rows),
          cols: Int(snapshot.pointee.cols)
        )
      }

      let builder = DebugRenderTraceBuilder(
        frame: frame,
        windowWidth: windowWidth,
        windowHeight: windowHeight,
        sidebarWidth: sidebarWidth,
        surfaceWidth: surface.width,
        surfaceHeight: surface.height,
        surfaceScale: Double(surface.scale),
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        hasActiveTab: hasActiveTab,
        terminalSnapshot: terminalSnapshot,
        commands: lastFrameCommands,
        limit: limit,
        pixelProbes: request.pixelProbes,
        pixelSampler: DebugPixelProbeSampler(surface: surface)
      )
      return jsonEncode(builder.response())
    }
  }

  public func pixelProbe(_ data: Data) -> DebugResponse {
    let body = data.isEmpty ? Data("{}".utf8) : data
    guard let request = try? JSONDecoder().decode(PixelProbeRequest.self, from: body) else {
      withRuntimeLock {
        appendError(kind: "pixel-probe.invalid", message: "invalid pixel probe request")
      }
      return jsonError("invalid pixel probe request")
    }

    return withRuntimeLock {
      let sampler = DebugPixelProbeSampler(surface: surface)
      return jsonEncode(sampler.response(frame: currentFrame, request: request))
    }
  }

  private func glyphDiagnosticsUnlocked() -> (loaded: Int, missingCodepoints: [String]) {
    var loaded = Set<String>()
    var missing = Set<String>()

    for command in lastFrameCommands {
      guard case .glyphRun(_, let text, _, _, _, _, _, _, _) = command else { continue }
      for scalar in text.unicodeScalars {
        let label = codepointLabel(scalar)
        if fontHasGlyph(for: scalar) {
          loaded.insert(label)
        } else {
          missing.insert(label)
        }
      }
    }

    return (loaded.count, missing.sorted())
  }

  private func fontHasGlyph(for scalar: UnicodeScalar) -> Bool {
    let chars = Array(String(scalar).utf16)
    guard !chars.isEmpty else { return false }
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    return chars.withUnsafeBufferPointer { charPtr in
      glyphs.withUnsafeMutableBufferPointer { glyphPtr in
        guard let charsBase = charPtr.baseAddress, let glyphsBase = glyphPtr.baseAddress else {
          return false
        }
        return CTFontGetGlyphsForCharacters(
          fontAtlas.font,
          charsBase,
          glyphsBase,
          chars.count
        )
      }
    }
  }

  private func codepointLabel(_ scalar: UnicodeScalar) -> String {
    let hex = String(scalar.value, radix: 16, uppercase: true)
    return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
  }
}
