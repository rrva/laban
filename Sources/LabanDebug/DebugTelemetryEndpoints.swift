import Foundation

extension HeadlessDebugRuntime {
  public func timingResponse() -> DebugResponse {
    withRuntimeLock {
      jsonEncode(
        TimingResponse(
          frame: currentFrame,
          lastFrameMs: timing.lastFrameMs,
          terminalPollMs: timing.terminalPollMs,
          snapshotMs: timing.snapshotMs,
          commandExtractionMs: timing.commandExtractionMs,
          renderMs: timing.renderMs,
          screenshotMs: timing.screenshotMs
        ))
    }
  }

  public func metricsResponse() -> DebugResponse {
    withRuntimeLock {
      jsonEncode(
        MetricsResponse(
          runId: runId,
          mode: mode,
          frame: currentFrame,
          uptimeMs: elapsedMs(since: startedAt),
          counters: MetricsCountersResponse(
            framesRendered: currentFrame,
            events: logs.eventSeq,
            inputEvents: logs.inputLogSeq,
            terminalLogEvents: logs.terminalLogSeq,
            errors: logs.errorSeq,
            screenshots: screenshotCount,
            tabs: model.tabs.count,
            sessions: model.tabs.count
          ),
          terminalBytes: TerminalByteMetricsResponse(
            input: logs.terminalBytes.input,
            output: logs.terminalBytes.output,
            terminalResponse: logs.terminalBytes.terminalResponse
          ),
          lastFrame: LastFrameMetricsResponse(
            commands: lastFrameCommands.count,
            cells: lastDrawStats.cells,
            glyphs: lastDrawStats.glyphs,
            backgroundRects: lastDrawStats.backgroundRects,
            images: lastDrawStats.images,
            cursor: lastDrawStats.cursor,
            lastFrameMs: timing.lastFrameMs,
            terminalPollMs: timing.terminalPollMs,
            snapshotMs: timing.snapshotMs,
            commandExtractionMs: timing.commandExtractionMs,
            renderMs: timing.renderMs
          )
        ))
    }
  }

  public func errors(since: Int) -> DebugResponse {
    withRuntimeLock {
      jsonEncode(logs.errorsResponse(since: since))
    }
  }

  public func terminalLogResponse(query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      jsonEncode(
        logs.terminalLogResponse(query: query, defaultSessionId: model.activeTab?.sessionId))
    }
  }

  public func inputLogResponse(since: Int) -> DebugResponse {
    withRuntimeLock {
      jsonEncode(logs.inputLogResponse(since: since))
    }
  }

  public func events(since: Int) -> DebugResponse {
    withRuntimeLock {
      jsonEncode(logs.eventsResponse(since: since))
    }
  }
}
