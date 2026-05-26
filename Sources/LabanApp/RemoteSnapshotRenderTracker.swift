import LabanCore

struct RemoteSnapshotRenderTracker {
  private var renderedGenerationByTab: [Tab.ID: UInt64] = [:]

  func terminalDirty(tabId: Tab.ID, generation: UInt64?, fallbackDirty: Bool) -> Bool {
    guard let generation else { return fallbackDirty }
    return renderedGenerationByTab[tabId] != generation
  }

  mutating func markRendered(tabId: Tab.ID, generation: UInt64?) {
    guard let generation else { return }
    renderedGenerationByTab[tabId] = generation
  }

  mutating func clear(tabId: Tab.ID) {
    renderedGenerationByTab.removeValue(forKey: tabId)
  }
}
