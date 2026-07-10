import Foundation
import LabanCore

// Route resolution, authorization, and dispatch for LabanControlServer.
// Split out of LabanControlServer.swift; behavior-preserving code movement.
extension LabanControlServer {
  func route(
    method: String,
    path: String,
    query: [String: String],
    body: Data,
    tokenTier: ControlTokenTier
  ) -> ControlResponse {
    var matchedRoute: ControlRoute?
    var pathParameters: [String: String] = [:]
    for candidate in ControlRouteCatalog.routes {
      guard let parameters = candidate.match(method: method, path: path) else {
        continue
      }
      matchedRoute = candidate
      pathParameters = parameters
      break
    }

    guard let route = matchedRoute else {
      return .error(404, "not found")
    }
    let request = ControlHTTPRequest(
      method: method,
      path: path,
      query: query,
      pathParameters: pathParameters,
      body: body)

    let intentID: String
    switch route.resolveIntentID(request, tokenTier) {
    case .resolved(let id):
      intentID = id
    case .failed(let response):
      return response
    }

    guard let descriptor = catalog.descriptor(id: intentID) else {
      return Self.missingDescriptorResponse(for: route)
    }
    if intentID == DebugActionIntentID.unsupported {
      return authorizeAndDispatch(
        route: route,
        request: request,
        tokenTier: tokenTier,
        descriptor: descriptor,
        intentID: intentID,
        body: body)
    }
    guard descriptor.availability.permits(surface) else {
      reportDeny(
        intentID: intentID,
        capability: descriptor.requiredCapability,
        reason: .surfaceUnavailable,
        targetSession: resolveTargetSession(request: request, body: body),
        tokenTier: tokenTier)
      return .error(404, "unavailable on \(surface)")
    }

    return authorizeAndDispatch(
      route: route,
      request: request,
      tokenTier: tokenTier,
      descriptor: descriptor,
      intentID: intentID,
      body: body)
  }

  func authorizeAndDispatch(
    route: ControlRoute,
    request: ControlHTTPRequest,
    tokenTier: ControlTokenTier,
    descriptor: IntentDescriptor,
    intentID: String,
    body: Data
  ) -> ControlResponse {
    let targetSession = resolveTargetSession(request: request, body: body)
    let granted = LabanControlPolicy.grants(for: tokenTier)
    let scope = LabanControlPolicy.tokenScope(for: tokenTier)
    let requiredCapability = descriptor.requiredCapability
    guard granted.contains(requiredCapability) else {
      reportDeny(
        intentID: intentID,
        capability: requiredCapability,
        reason: .forbiddenCapability,
        targetSession: targetSession,
        tokenTier: tokenTier)
      return .error(403, "forbidden")
    }
    let bodyHashForConstraint = (body.isEmpty ? nil : computeSHA256(body))
    guard
      LabanControlPolicy.authorize(
        intentID: intentID,
        catalog: catalog,
        granted: granted,
        targetSession: targetSession,
        tokenScope: scope,
        tokenTier: tokenTier,
        method: request.method,
        path: request.path,
        query: queryForConstraint(request.query),
        bodySHA256: bodyHashForConstraint)
    else {
      reportDeny(
        intentID: intentID,
        capability: requiredCapability,
        reason: .forbiddenScope,
        targetSession: targetSession,
        tokenTier: tokenTier)
      return .error(403, "forbidden")
    }

    let response = route.dispatch(self, request, tokenTier)
    if (200..<300).contains(response.status) {
      reportAuthorize(
        intentID: intentID,
        capability: requiredCapability,
        targetSession: targetSession,
        tokenTier: tokenTier)
    }
    return response
  }

  func resolveTargetSession(request: ControlHTTPRequest, body: Data) -> String? {
    if let id = request.pathParameters["id"], !id.isEmpty {
      return id
    }
    for key in ["sessionID", "sessionId", "targetSessionID", "targetSessionId"] {
      if let value = request.query[key], !value.isEmpty {
        return value
      }
    }
    if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
      for key in ["sessionID", "sessionId", "targetSessionID", "targetSessionId"] {
        if let value = json[key] as? String, !value.isEmpty {
          return value
        }
      }
    }
    return nil
  }

  func legacyQueryInput(
    intentID: String,
    params: [String: String],
    tokenTier: ControlTokenTier
  ) -> LegacyDebugQueryInput {
    let scopedSessionID: String?
    switch tokenTier {
    case .sessionObserve(let sessionID), .approvedSession(let sessionID, _, _, _):
      scopedSessionID = sessionID
    case .appObserve, .fixture:
      scopedSessionID = nil
    }
    let readRedaction: ControlReadRedaction =
      switch tokenTier {
      case .appObserve: .appObserveSummary
      case .sessionObserve, .approvedSession: .sessionObserveSummary
      case .fixture: .none
      }
    return LegacyDebugQueryInput(
      intentID: intentID,
      params: params,
      scopedSessionID: scopedSessionID,
      readRedaction: readRedaction)
  }

  func dispatchDebugAction(_ request: ControlHTTPRequest, tokenTier: ControlTokenTier)
    -> ControlResponse
  {
    guard let envelope = try? JSONDecoder().decode(DebugActionEnvelope.self, from: request.body)
    else {
      return .error(400, "bad request")
    }

    guard let intentID = DebugActionIntentID.intentID(forAction: envelope.action) else {
      return router.route(
        .unsupportedDebugAction(UnsupportedDebugActionInput(action: envelope.action)))
    }

    let scopedSessionID = sessionID(from: tokenTier)
    switch surface {
    case .gui:
      return dispatchGUIAction(
        intentID: intentID, request: request, scopedSessionID: scopedSessionID)
    case .headless:
      return router.route(
        .legacyDebugAction(
          LegacyDebugActionInput(
            intentID: intentID,
            action: envelope.action,
            body: request.body,
            scopedSessionID: scopedSessionID)))
    }
  }

  func dispatchGUIAction(
    intentID: String,
    request: ControlHTTPRequest,
    scopedSessionID: String?
  ) -> ControlResponse {
    switch intentID {
    case "terminal.scrollViewport", "command.propose":
      guard let envelope = try? JSONDecoder().decode(DebugActionEnvelope.self, from: request.body)
      else {
        return .error(400, "bad request")
      }
      return router.route(
        .legacyDebugAction(
          LegacyDebugActionInput(
            intentID: intentID,
            action: envelope.action,
            body: request.body,
            scopedSessionID: scopedSessionID)))
    default:
      return .error(404, "unavailable on gui")
    }
  }

  func queryForConstraint(_ query: [String: String]) -> String {
    var pairs: [String] = []
    for (key, value) in query.sorted(by: { $0.key < $1.key }) {
      pairs.append("\(key)=\(value)")
    }
    return pairs.joined(separator: "&")
  }

  func sessionID(from tokenTier: ControlTokenTier?) -> String? {
    guard let tokenTier else { return nil }
    switch tokenTier {
    case .sessionObserve(let sessionID), .approvedSession(let sessionID, _, _, _):
      return sessionID
    case .appObserve, .fixture:
      return nil
    }
  }

  static func missingDescriptorResponse(for route: ControlRoute) -> ControlResponse {
    if route.endpoint.binding.method == "POST" && route.endpoint.binding.path == "/debug/actions" {
      return .error(400, "unsupported action")
    }
    return .error(404, "not found")
  }

  func evaluateAuthorization(
    peerOutcome: GuardOutcome,
    authorization: String?
  ) -> (GuardOutcome, ControlTokenTier?) {
    guard peerOutcome == .ok else {
      return (.forbidden, nil)
    }
    guard
      let authorization,
      authorization.count > 7,
      authorization.lowercased().hasPrefix("bearer ")
    else {
      return (.unauthorized, nil)
    }
    let presented = String(authorization.dropFirst(7))
    tokenLock.lock()
    defer { tokenLock.unlock() }
    for (token, tier) in tokens {
      if Self.constantTimeEquals(presented, token) {
        return (.ok, tier)
      }
    }
    return (.unauthorized, nil)
  }

  /// Retained for backward-compatible unit tests.
  public static func evaluateAuthorization(
    peerOutcome: GuardOutcome,
    authorization: String?,
    tokens: [String: ControlTokenTier]
  ) -> (GuardOutcome, ControlTokenTier?) {
    guard peerOutcome == .ok else {
      return (.forbidden, nil)
    }
    guard
      let authorization,
      authorization.count > 7,
      authorization.lowercased().hasPrefix("bearer ")
    else {
      return (.unauthorized, nil)
    }
    let presented = String(authorization.dropFirst(7))
    for (token, tier) in tokens {
      if constantTimeEquals(presented, token) {
        return (.ok, tier)
      }
    }
    return (.unauthorized, nil)
  }

  func resolveAuthorization(
    authorization: String?,
    connectionTier: ControlTokenTier?
  ) -> (GuardOutcome, ControlTokenTier?) {
    if let connectionTier {
      return (.ok, connectionTier)
    }
    return evaluateAuthorization(peerOutcome: .ok, authorization: authorization)
  }
}
