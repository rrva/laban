import Foundation
import LabanCore
import LabanRenderer

extension HeadlessDebugRuntime {
  func transparencyState() -> DebugResponse {
    withRuntimeLock { jsonEncode(transparencyStateUnlocked()) }
  }

  func transparencyStateUnlocked() -> TerminalTransparencyDebugResponse {
    let status = rendererBackend.rendererStatus
    let presentStats =
      (rendererBackend as? DisplayLinkPresentingRenderer)?.presentDisplayLinkStats(reset: false)
    let misses = presentStats?["estimatedMissedVsyncs"] ?? 0
    let managedImage = backgroundImageStore.managedImage
    return TerminalTransparencyDebugResponse(
      requestedOpacity: requestedTransparency.backgroundOpacity,
      effectiveOpacity: effectiveTransparency.backgroundOpacity,
      requestedBackdropStyle: requestedTransparency.backdropStyle.rawValue,
      effectiveBackdropStyle: effectiveTransparency.backdropStyle.rawValue,
      backgroundImageScaling: requestedTransparency.backgroundImageScaling.rawValue,
      backgroundImageState:
        requestedTransparency.backdropStyle == .image
        ? TerminalBackgroundImageAvailability.headlessUnsupported.rawValue
        : TerminalBackgroundImageAvailability.none.rawValue,
      backgroundImageIdentifier: managedImage?.identifier,
      backgroundImagePixelWidth: managedImage?.pixelWidth,
      backgroundImagePixelHeight: managedImage?.pixelHeight,
      backgroundImageContentDigest: managedImage?.contentDigest,
      backgroundImageImportCount: backgroundImageStore.importCount,
      backgroundImageDecodeCount: backgroundImageStore.decodeCount,
      backgroundImageFileReadCount: backgroundImageStore.fileReadCount,
      backgroundImageApplyCount: 0,
      backgroundImageRedrawCount: 0,
      applyToExplicitCellBackgrounds:
        requestedTransparency.applyToExplicitCellBackgrounds,
      forceOpaqueReason: effectiveTransparency.forceOpaqueReason?.rawValue,
      surfaceOpaque: effectiveTransparency.isSurfaceOpaque,
      effectiveGlyphAntialiasing: status.vectorSubpixelLayout ?? "rendererDefault",
      effectiveGlyphAntialiasingReason: status.vectorSubpixelFallbackReason,
      snapshotExplicitBackgroundCapability:
        TerminalSnapshotBackgroundCapability.inProcess.rawValue,
      configuredRenderer: status.configuredRenderer,
      effectiveRenderer: status.effectiveRenderer,
      themeName: Theme.current.name,
      themeIsDark: Theme.current.isDark,
      effectiveAppearance: "headless",
      backdropSubviewCount: 0,
      backdropSubviewKind: TerminalBackdropStyle.none.rawValue,
      systemReduceTransparency: false,
      reduceTransparencyOverride: reduceTransparencyOverride,
      effectiveReduceTransparency: accessibilityDisplayFlags.reduceTransparency,
      nativeFullscreen: false,
      accessibilityRefreshCount: transparencyAccessibilityRefreshCount,
      effectiveTransparencyApplyCount: effectiveTransparencyApplyCount,
      transparencyRenderWakeCount: transparencyRenderWakeCount,
      rendererPresentCount: max(0, currentFrame - transparencyRendererPresentBaseline),
      presentIntervalDeadlineMisses: max(0, Int(misses.rounded())))
  }

  func setBackgroundTransparencyUnlocked(
    _ request: SetBackgroundTransparencyActionRequest
  ) -> DebugResponse {
    guard request.opacity.isFinite else {
      return jsonError("opacity must be finite")
    }
    let next = TerminalTransparencyConfiguration(
      backgroundOpacity: request.opacity,
      applyToExplicitCellBackgrounds: request.applyToExplicitCellBackgrounds,
      backdropStyle: request.backdropStyle ?? requestedTransparency.backdropStyle,
      backgroundImageScaling: requestedTransparency.backgroundImageScaling)
    guard next != requestedTransparency else { return actionResult(ok: true) }
    requestedTransparency = next
    resolveTransparencyAndRenderUnlocked()
    return actionResult(ok: true)
  }

  func resetTransparencyDiagnosticsUnlocked() -> DebugResponse {
    _ = (rendererBackend as? DisplayLinkPresentingRenderer)?.presentDisplayLinkStats(reset: true)
    transparencyAccessibilityRefreshCount = 0
    effectiveTransparencyApplyCount = 0
    transparencyRenderWakeCount = 0
    transparencyRendererPresentBaseline = currentFrame
    backgroundImageStore.resetDiagnostics()
    return actionResult(ok: true)
  }

  func setBackgroundSourceUnlocked(
    _ request: SetBackgroundSourceActionRequest
  ) -> DebugResponse {
    guard requestedTransparency.backdropStyle != request.source else {
      return actionResult(ok: true)
    }
    requestedTransparency.backdropStyle = request.source
    resolveTransparencyAndRenderUnlocked()
    return actionResult(ok: true)
  }

  func setBackgroundImageScalingUnlocked(
    _ request: SetBackgroundImageScalingActionRequest
  ) -> DebugResponse {
    requestedTransparency.backgroundImageScaling = request.scaling
    return actionResult(ok: true)
  }

  func importBackgroundImageUnlocked(
    _ request: ImportBackgroundImageActionRequest
  ) -> DebugResponse {
    let sourceURL: URL
    do {
      sourceURL = try DebugFixtureResolver.resolve(request.path, root: fixtureRootURL)
      _ = try backgroundImageStore.importImage(from: sourceURL)
    } catch {
      return jsonError("background image fixture import rejected")
    }
    requestedTransparency.backgroundImageScaling = request.scaling
    requestedTransparency.backdropStyle = .image
    resolveTransparencyAndRenderUnlocked()
    return actionResult(ok: true)
  }

  func removeBackgroundImageUnlocked() -> DebugResponse {
    backgroundImageStore.removeImage()
    requestedTransparency.backdropStyle = .none
    resolveTransparencyAndRenderUnlocked()
    return actionResult(ok: true)
  }

  func setReduceTransparencyOverrideUnlocked(
    _ request: SetReduceTransparencyOverrideActionRequest
  ) -> DebugResponse {
    guard reduceTransparencyOverride != request.enabled else {
      return actionResult(ok: true)
    }
    reduceTransparencyOverride = request.enabled
    accessibilityDisplayFlags.reduceTransparency = request.enabled ?? false
    transparencyAccessibilityRefreshCount += 1

    let previous = effectiveTransparency
    resolveTransparencyUnlocked()
    if effectiveTransparency != previous {
      applyEffectiveTransparencyUnlocked()
    }
    // Match TerminalBitmapView's single coalesced accessibility wake even if
    // removing an override resolves to the same effective system value.
    transparencyRenderWakeCount += 1
    renderFrameUnlocked()
    return actionResult(ok: true)
  }

  private func resolveTransparencyAndRenderUnlocked() {
    let previous = effectiveTransparency
    resolveTransparencyUnlocked()
    guard effectiveTransparency != previous else { return }
    applyEffectiveTransparencyUnlocked()
    transparencyRenderWakeCount += 1
    renderFrameUnlocked()
  }

  private func resolveTransparencyUnlocked() {
    effectiveTransparency = TerminalTransparencyPolicy.resolve(
      requested: requestedTransparency,
      reduceTransparency: accessibilityDisplayFlags.reduceTransparency,
      nativeFullscreen: false,
      supportsBehindWindowBlur: false,
      backgroundImageAvailability:
        requestedTransparency.backdropStyle == .image ? .headlessUnsupported : .none,
      snapshotBackgroundCapability: .inProcess,
      headless: true)
  }

  private func applyEffectiveTransparencyUnlocked() {
    rendererBackend.setSurfaceTransparency(
      RendererSurfaceTransparency(isOpaque: effectiveTransparency.isSurfaceOpaque))
    effectiveTransparencyApplyCount += 1
  }
}
