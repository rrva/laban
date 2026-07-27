import LabanCore

struct RemoteSnapshotRenderTracker {
  private struct RenderedIdentity: Equatable {
    var incarnationId: String?
    var generation: UInt64
  }
  private var renderedIdentityByTab: [Tab.ID: RenderedIdentity] = [:]

  func terminalDirty(
    tabId: Tab.ID,
    incarnationId: String? = nil,
    generation: UInt64?,
    fallbackDirty: Bool
  ) -> Bool {
    guard let generation else { return fallbackDirty }
    return renderedIdentityByTab[tabId]
      != RenderedIdentity(incarnationId: incarnationId, generation: generation)
  }

  mutating func markRendered(
    tabId: Tab.ID,
    incarnationId: String? = nil,
    generation: UInt64?
  ) {
    guard let generation else { return }
    renderedIdentityByTab[tabId] = RenderedIdentity(
      incarnationId: incarnationId,
      generation: generation)
  }

  mutating func clear(tabId: Tab.ID) {
    renderedIdentityByTab.removeValue(forKey: tabId)
  }
}
