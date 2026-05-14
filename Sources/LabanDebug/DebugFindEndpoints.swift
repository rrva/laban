import Foundation

extension HeadlessDebugRuntime {
  public func findStart(_ data: Data) -> DebugResponse {
    withRuntimeLock {
      guard let request = try? JSONDecoder().decode(FindStartRequest.self, from: data) else {
        return jsonError("invalid find.start request")
      }
      return DebugFindActions(runtime: self).start(request)
    }
  }

  public func findStep(_ data: Data) -> DebugResponse {
    withRuntimeLock {
      guard let request = try? JSONDecoder().decode(FindStepRequest.self, from: data) else {
        return jsonError("invalid find.step request")
      }
      return DebugFindActions(runtime: self).step(request)
    }
  }

  public func findStop(_ data: Data) -> DebugResponse {
    withRuntimeLock {
      guard let request = try? JSONDecoder().decode(FindSessionRequest.self, from: data) else {
        return jsonError("invalid find.stop request")
      }
      return DebugFindActions(runtime: self).stop(request)
    }
  }

  public func findState(query: [String: String]) -> DebugResponse {
    withRuntimeLock {
      let request = FindSessionRequest(
        sessionID: query["sessionID"],
        sessionId: query["sessionId"]
      )
      return DebugFindActions(runtime: self).state(request)
    }
  }
}
