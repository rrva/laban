import CryptoKit
import Darwin
import Foundation
import LabanCore

// MARK: - Lazy Attach
//
// A process already running inside a registered session asks for one
// server-resolved request via POST /control/session/attach/request. Split
// out of LabanControlServer.swift; behavior-preserving code movement.
extension LabanControlServer {
  final class LazyApprovalResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _decision: ControlAttachApprovalDecision = .deny

    var decision: ControlAttachApprovalDecision {
      lock.lock()
      defer { lock.unlock() }
      return _decision
    }

    func set(_ decision: ControlAttachApprovalDecision) {
      lock.lock()
      _decision = decision
      lock.unlock()
    }
  }

  func handleLazyAttachRequest(
    clientFD: Int32,
    body: Data,
    peerPID: pid_t?,
    appObserveToken: String?
  ) -> ControlResponse {
    guard let peerPID = peerPID, peerPID > 0 else {
      reportLazyAttachDeny(sessionID: nil, reason: "processIdentityUnavailable")
      return .error(403, "processIdentityUnavailable")
    }

    let token = appObserveToken.flatMap { header -> String? in
      let value = header.trimmingCharacters(in: .whitespaces)
      guard value.lowercased().hasPrefix("bearer ") else { return nil }
      return String(value.dropFirst(7))
    }
    guard let token, validateAppObserveToken(token) else {
      return .error(401, "unauthorized")
    }

    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let clientRequestID = json["clientRequestID"] as? String,
      !clientRequestID.isEmpty,
      UUID(uuidString: clientRequestID) != nil,
      let cliCommand = json["cliCommand"] as? String,
      !cliCommand.isEmpty,
      let intendedRequest = json["intendedRequest"] as? [String: Any],
      let method = intendedRequest["method"] as? String,
      !method.isEmpty,
      let path = intendedRequest["path"] as? String,
      !path.isEmpty
    else {
      return .error(400, "bad request")
    }

    let queryString = intendedRequest["query"] as? String ?? ""
    let bodyData: Data?
    if let bodyBase64 = intendedRequest["bodyBase64"] as? String {
      guard let decoded = Data(base64Encoded: bodyBase64) else {
        return .error(400, "bad request")
      }
      bodyData = decoded
    } else {
      bodyData = nil
    }
    let bodySHA256 = intendedRequest["bodySHA256"] as? String
    let computedHash = bodyData.map { computeSHA256($0) }
    if bodyData != nil, bodySHA256 == nil || bodySHA256 != computedHash {
      return .error(400, "bodySHA256 mismatch")
    }
    if bodyData == nil, bodySHA256 != nil {
      return .error(400, "bodySHA256 mismatch")
    }
    if let bodyData, bodyData.count > Self.maxLazyAttachBodySize {
      return .error(413, "request body too large")
    }

    var peerIdentity: ControlProcessIdentity
    switch processTreeInspector.identity(for: peerPID) {
    case .some(let identity) where identity.uid == getuid():
      peerIdentity = identity
    default:
      reportLazyAttachDeny(sessionID: nil, reason: "processIdentityUnavailable")
      return .error(403, "processIdentityUnavailable")
    }
    if let auditToken = Self.peerAuditToken(clientFD: clientFD) {
      peerIdentity.auditToken = auditToken
    }
    guard let peerStartTime = peerIdentity.startTime else {
      reportLazyAttachDeny(sessionID: nil, reason: "processIdentityUnavailable")
      return .error(403, "processIdentityUnavailable")
    }

    guard let shellSession = resolveUniqueShellSessionAncestor(peerPID: peerPID) else {
      reportLazyAttachDeny(sessionID: nil, reason: "notDescendantOfRegisteredSession")
      return .error(403, "notDescendantOfRegisteredSession")
    }

    let (sessionID, shellIdentity) = shellSession

    guard
      let chain = resolveAttachProcessChain(
        peerPID: peerPID,
        shellPID: shellIdentity.shellPID,
        peerIdentity: peerIdentity)
    else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "notDescendantOfRegisteredSession")
      return .error(403, "notDescendantOfRegisteredSession")
    }

    guard let principal = chain.principal else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "principalIdentityUnavailable")
      return .error(403, "principalIdentityUnavailable")
    }
    guard let principalStartTime = principal.identity.startTime else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "processIdentityUnavailable")
      return .error(403, "processIdentityUnavailable")
    }

    var identityWithSigning = principal.identity
    if let signing = codeSigningInspector.signingIdentity(
      forLivePID: principal.identity.pid,
      startTime: principalStartTime,
      auditToken: principal.identity.auditToken)
    {
      identityWithSigning.signing = signing
    }
    let principalWithSigning = ControlAttachPrincipal(
      identity: identityWithSigning,
      isGenericInterpreter: ControlAttachPrincipal.isGenericInterpreter(identityWithSigning),
      isPersistable: ControlAttachPrincipal.isPersistable(identityWithSigning),
      helperChain: principal.helperChain)

    let (
      _, resolvedIntentID, _, resolvedSensitivity, _
    ) = resolveRouteAndIntent(
      method: method,
      path: path,
      query: Self.parseQueryString(queryString),
      body: bodyData ?? Data(),
      sessionID: sessionID)

    guard let resolvedIntentID = resolvedIntentID,
      ControlLazyAttachAllowlist.isAllowlisted(
        method: method, path: path, intentID: resolvedIntentID)
    else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "lazyRouteNotAllowed")
      return .error(403, "lazyRouteNotAllowed")
    }

    let rawSessionRequest = cliCommand == "session.request"
    let allowlistMatch = ControlLazyAttachAllowlist.entry(
      method: method, path: path, intentID: resolvedIntentID)
    let isPersistableOperation = allowlistMatch?.persistable == true
    let canPersist =
      principalWithSigning.isPersistable && isPersistableOperation
      && !rawSessionRequest

    guard let descriptor = catalog.descriptor(id: resolvedIntentID) else {
      return .error(404, "not found")
    }
    guard descriptor.availability.permits(surface) else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "surfaceUnavailable")
      return .error(404, "unavailable on \(surface)")
    }

    let routeIDForRecord = "\(method) \(path)"
    let sideEffectClass = sideEffectClassFor(descriptor.sideEffects)
    let capabilities = [descriptor.requiredCapability]
    let principalIdentityFingerprint = principalWithSigning.identity.stablePrincipalFingerprint

    let approvalID = "\(sessionID.prefix(8))-\(clientRequestID.prefix(8))"
    let context = ControlAttachApprovalContext(
      approvalID: approvalID,
      sessionID: sessionID,
      peerPID: peerPID,
      peerStartTime: peerStartTime,
      auditToken: peerIdentity.auditToken,
      principalFingerprint: principalWithSigning.identity.fingerprint,
      method: method,
      path: path,
      query: queryString,
      bodySHA256: computedHash,
      resolvedRouteID: routeIDForRecord,
      resolvedIntentID: resolvedIntentID,
      capabilities: capabilities,
      maxDataSensitivity: resolvedSensitivity,
      allowedSideEffectClasses: [sideEffectClass])

    let matchingRecord = approvalStore.findMatching(
      principal: principalWithSigning,
      sessionID: sessionID,
      shellIdentityFingerprint: shellIdentity.fingerprint,
      routeID: routeIDForRecord,
      intentID: resolvedIntentID,
      capabilities: Set(capabilities),
      dataSensitivity: resolvedSensitivity,
      sideEffectClass: sideEffectClass,
      signingInspector: codeSigningInspector)

    if let matchingRecord = matchingRecord {
      guard revalidateLazyAttachContext(context, clientFD: clientFD, body: bodyData ?? Data())
      else {
        reportLazyAttachDeny(sessionID: sessionID, reason: "sessionChanged")
        return .error(409, "sessionChanged")
      }
      let approvedToken = Self.makeToken()
      #if DEBUG
        onApprovedTokenMintedForTesting?(approvedToken)
      #endif
      // Mint a family-scoped tier, not a request-exact one: a persisted
      // record now auto-approves any family intent for this session (per
      // Milestone 2), so the token this dispatch actually uses must carry the
      // family authorization, not just this one route/intent. The token is
      // still minted, used for exactly this one route() dispatch below, then
      // discarded; Allow Once/Always both stay one-dispatch-per-request, the
      // family reach comes from the persisted record being consulted again on
      // the next request, not from a long-lived token.
      let approvedTier = ControlTokenTier.approvedSessionFamily(
        sessionID: sessionID,
        approvalID: matchingRecord.id,
        capabilities: Array(ControlSessionObserveFamily.capabilities))
      tokenLock.lock()
      tokens[approvedToken] = approvedTier
      tokenLock.unlock()
      reportLazyAttachAutoApproved(
        sessionID: sessionID, approvalID: matchingRecord.id, intentID: resolvedIntentID)
      let downstream = route(
        method: method,
        path: path,
        query: Self.parseQueryString(queryString),
        body: bodyData ?? Data(),
        tokenTier: approvedTier)
      tokenLock.lock()
      tokens.removeValue(forKey: approvedToken)
      tokenLock.unlock()
      approvalStore.updateLastUsed(id: matchingRecord.id)
      return lazyAttachResponse(
        sessionID: sessionID,
        approval: "always",
        downstream: downstream)
    }

    lazyAttachLock.lock()
    let existingKey = pendingLazyAttachRequests.first {
      $0.value.peerPID == peerPID && $0.value.resolvedIntentID == resolvedIntentID
    }?.key
    if existingKey != nil {
      lazyAttachLock.unlock()
      reportLazyAttachDeny(sessionID: sessionID, reason: "approvalRateLimited")
      return .error(429, "approvalRateLimited")
    }
    if let lastDeny = lastLazyDenyByPrincipalFingerprint[principalWithSigning.identity.fingerprint],
      Date().timeIntervalSince(lastDeny) < lazyDenyCooldown
    {
      lazyAttachLock.unlock()
      reportLazyAttachDeny(sessionID: sessionID, reason: "approvalRateLimited")
      return .error(429, "approvalRateLimited")
    }
    guard pendingLazyAttachRequests.count < maxConcurrentPendingLazyAttachRequests else {
      lazyAttachLock.unlock()
      reportLazyAttachDeny(sessionID: sessionID, reason: "approvalRateLimited")
      return .error(429, "approvalRateLimited")
    }
    let pendingRequestID = UUID().uuidString
    pendingLazyAttachRequests[pendingRequestID] = context
    lazyAttachLock.unlock()

    reportLazyAttachRequest(sessionID: sessionID, intentID: resolvedIntentID)

    let delegate = approvalDelegate
    let verifiedDisplayName =
      principalWithSigning.isPersistable
      ? principalWithSigning.identity.signing?.displayName
        ?? principalWithSigning.identity.executableBaseName
      : principalWithSigning.identity.executableBaseName
    let persistenceDisabledReason: String?
    if canPersist {
      persistenceDisabledReason = nil
    } else if !principalWithSigning.isPersistable {
      persistenceDisabledReason = "This app is not a stable signed application."
    } else {
      persistenceDisabledReason = "This operation cannot be remembered for this route."
    }
    // The dialog describes the whole family, not this one request: the grant
    // it names, if approved, authorizes any family intent for the session
    // (Milestone 2). Data/Permission rows reflect the family's ordering-max
    // sensitivity and full capability set; this is presentation only, it does
    // not widen or narrow what is actually authorized.
    let request = ControlAttachApprovalRequest(
      id: approvalID,
      principalDisplayName: verifiedDisplayName,
      principalIsVerified: principalWithSigning.isPersistable,
      helperChainSummary: chain.helperChainSummary,
      principalPath: principalWithSigning.identity.executablePath,
      sessionDisplay: "\(sessionID.suffix(4))",
      operationSummary: descriptor.summary,
      dataSensitivity: ControlSessionObserveFamily.maxDataSensitivity(catalog: catalog),
      capabilities: ControlSessionObserveFamily.capabilities.map(\Capability.rawValue).sorted(),
      canPersist: canPersist,
      persistenceDisabledReason: persistenceDisabledReason,
      grantsSessionReadFamily: true)

    let semaphore = DispatchSemaphore(value: 0)
    let approvalResult = LazyApprovalResult()

    delegate?.requestControlAttachApproval(request) { [weak self] approvedDecision in
      guard let self else { return }
      self.lazyAttachLock.lock()
      self.pendingLazyAttachRequests.removeValue(forKey: pendingRequestID)
      self.lazyAttachLock.unlock()
      approvalResult.set(approvedDecision)
      semaphore.signal()
    }

    let timeoutResult = semaphore.wait(timeout: .now() + lazyAttachApprovalTimeout)
    if timeoutResult == .timedOut {
      lazyAttachLock.lock()
      pendingLazyAttachRequests.removeValue(forKey: pendingRequestID)
      lastLazyDenyByPrincipalFingerprint[principalWithSigning.identity.fingerprint] = Date()
      lazyAttachLock.unlock()
      reportLazyAttachDeny(sessionID: sessionID, reason: "approvalTimeout")
      return .error(408, "approvalTimeout")
    }

    switch approvalResult.decision {
    case .deny:
      lazyAttachLock.lock()
      lastLazyDenyByPrincipalFingerprint[principalWithSigning.identity.fingerprint] = Date()
      lazyAttachLock.unlock()
      reportLazyAttachDeny(sessionID: sessionID, reason: "userDenied")
      return .error(403, "userDenied")
    case .allowOnce, .alwaysAllowSignedIdentity:
      break
    }

    guard revalidateLazyAttachContext(context, clientFD: clientFD, body: bodyData ?? Data()) else {
      lazyAttachLock.lock()
      lastLazyDenyByPrincipalFingerprint[principalWithSigning.identity.fingerprint] = Date()
      lazyAttachLock.unlock()
      reportLazyAttachDeny(sessionID: sessionID, reason: "sessionChanged")
      return .error(409, "sessionChanged")
    }

    let effectiveDecision: ControlAttachApprovalDecision
    let decision = approvalResult.decision
    if decision == .alwaysAllowSignedIdentity, !canPersist {
      effectiveDecision = .allowOnce
    } else {
      effectiveDecision = decision
    }

    if effectiveDecision == .alwaysAllowSignedIdentity {
      let signingRequirement = principalWithSigning.identity.signing?.designatedRequirement ?? ""
      // One record persists the whole family, not this one request (Milestone
      // 2): every field below is the family-wide value, so any later family
      // read for this (principal, session) auto-approves through
      // findMatching, not just a repeat of this exact route/intent.
      //
      // `session.detail`'s allowlist entry carries the literal template route
      // `GET /debug/sessions/<id>` (path-parameterized); a real request's
      // routeID is always the concrete `GET /debug/sessions/<sessionID>`
      // (resolveRouteAndIntent builds routeID from the raw incoming path, and
      // C12 guarantees `<id>` equals this approved session for any request
      // that can legitimately succeed). findMatching does exact string
      // containment with no wildcard support, so the literal template would
      // never match a live request and session.detail auto-approval would
      // silently fail; substitute the concrete sessionID here so the stored
      // routeID matches what a real dispatch computes.
      let familyRouteIDs = Array(
        Set(
          ControlLazyAttachAllowlist.entries.map {
            $0.routeID.replacingOccurrences(of: "<id>", with: sessionID)
          })
      ).sorted()
      let familySideEffectClasses = Array(
        Set(
          ControlSessionObserveFamily.intentIDs.compactMap { intentID in
            catalog.descriptor(id: intentID).map { sideEffectClassFor($0.sideEffects) }
          })
      ).sorted()
      let record = ControlAttachApprovalRecord(
        id: approvalID,
        displayName: principalWithSigning.identity.displayName,
        bundleIdentifier: principalWithSigning.identity.signing?.bundleIdentifier,
        signing: principalWithSigning.identity.signing ?? ControlCodeSigningIdentity(),
        signingRequirement: signingRequirement,
        sessionID: sessionID,
        shellIdentityFingerprint: shellIdentity.fingerprint,
        allowedRouteIDs: familyRouteIDs,
        allowedIntentIDs: Array(ControlSessionObserveFamily.intentIDs),
        capabilities: Array(ControlSessionObserveFamily.capabilities),
        maxDataSensitivity: ControlSessionObserveFamily.maxDataSensitivity(catalog: catalog),
        allowedSideEffectClasses: familySideEffectClasses,
        principalIdentityFingerprint: principalIdentityFingerprint)
      approvalStore.add(record)
    }

    let approvedToken = Self.makeToken()
    #if DEBUG
      onApprovedTokenMintedForTesting?(approvedToken)
    #endif
    // Same family-scoped mint as the auto-approve site above: this fresh
    // approval (Allow Once or Always) grants the whole family for the
    // session, not just this one route/intent. The token still covers
    // exactly this one route() dispatch below and is discarded immediately
    // after; Allow Once does not become long-lived, the family reach for
    // later requests comes only from the persisted record (Always) being
    // consulted again, never from this token outliving the dispatch.
    let approvedTier = ControlTokenTier.approvedSessionFamily(
      sessionID: sessionID,
      approvalID: approvalID,
      capabilities: Array(ControlSessionObserveFamily.capabilities))
    tokenLock.lock()
    tokens[approvedToken] = approvedTier
    tokenLock.unlock()
    reportLazyAttachApproved(
      sessionID: sessionID, approvalID: approvalID, intentID: resolvedIntentID,
      mode: effectiveDecision == .alwaysAllowSignedIdentity ? "always" : "once")
    let downstream = route(
      method: method,
      path: path,
      query: Self.parseQueryString(queryString),
      body: bodyData ?? Data(),
      tokenTier: approvedTier)
    tokenLock.lock()
    tokens.removeValue(forKey: approvedToken)
    tokenLock.unlock()
    return lazyAttachResponse(
      sessionID: sessionID,
      approval: effectiveDecision == .alwaysAllowSignedIdentity ? "always" : "once",
      downstream: downstream)
  }

  func validateAppObserveToken(_ token: String) -> Bool {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    for (storedToken, tier) in tokens {
      if Self.constantTimeEquals(storedToken, token) { return tier == .appObserve }
    }
    return false
  }

  func resolveUniqueShellSessionAncestor(
    peerPID: pid_t
  ) -> (sessionID: String, shell: RegisteredAttachShellIdentity)? {
    shellIdentityLock.lock()
    let identities = attachShellIdentitiesBySessionID
    shellIdentityLock.unlock()

    var matched: (sessionID: String, shell: RegisteredAttachShellIdentity)?
    var currentPID: pid_t? = peerPID

    while let pid = currentPID, pid > 1 {
      guard let identity = processTreeInspector.identity(for: pid),
        identity.uid == getuid()
      else {
        // Ancestors above a privilege boundary (non-same-uid, or identity
        // unresolvable) cannot extend a same-uid chain. If a shell was
        // already matched below this boundary, the nearer attribution is
        // correct and the walk stops here. If nothing matched yet, the
        // peer-to-shell chain is broken and resolution fails closed.
        if let matched { return matched }
        return nil
      }
      for (sessionID, shell) in identities where shell.shellPID == pid {
        if matched != nil {
          return nil
        }
        guard let shellStartTime = shell.shellStartTime,
          let currentStartTime = identity.startTime,
          currentStartTime == shellStartTime,
          shell.shellUID == identity.uid
        else {
          return nil
        }
        matched = (sessionID, shell)
      }
      currentPID = processTreeInspector.parentPID(of: pid)
    }

    guard let matched else { return nil }
    return matched
  }

  func resolveAttachProcessChain(
    peerPID: pid_t,
    shellPID: pid_t,
    peerIdentity: ControlProcessIdentity? = nil
  ) -> ControlAttachProcessChain? {
    var entries: [ControlProcessIdentity] = []
    var currentPID: pid_t? = peerPID
    while let pid = currentPID, pid > 0 {
      let identity: ControlProcessIdentity
      if let peerIdentity, pid == peerPID {
        identity = peerIdentity
      } else {
        guard let lookedUp = processTreeInspector.identity(for: pid) else {
          return nil
        }
        identity = lookedUp
      }
      guard identity.uid == getuid(), identity.startTime != nil else {
        return nil
      }
      entries.append(identity)
      if pid == shellPID { break }
      currentPID = processTreeInspector.parentPID(of: pid)
    }
    guard let last = entries.last, last.pid == shellPID else { return nil }
    return ControlAttachProcessChain(entries: entries)
  }

  func resolveRouteAndIntent(
    method: String,
    path: String,
    query: [String: String],
    body: Data,
    sessionID: String
  ) -> (
    routeID: String?,
    intentID: String?,
    capability: Capability?,
    sensitivity: String,
    sideEffectClass: String
  ) {
    for candidate in ControlRouteCatalog.routes {
      guard candidate.match(method: method, path: path) != nil else { continue }
      let request = ControlHTTPRequest(
        method: method,
        path: path,
        query: query,
        pathParameters: [:],
        body: body)
      switch candidate.resolveIntentID(request, .sessionObserve(sessionID: sessionID)) {
      case .resolved(let intentID):
        guard let descriptor = catalog.descriptor(id: intentID) else { continue }
        return (
          "\(method) \(path)",
          intentID,
          descriptor.requiredCapability,
          descriptor.dataSensitivity.rawValue,
          sideEffectClassFor(descriptor.sideEffects)
        )
      case .failed:
        continue
      }
    }
    return (nil, nil, nil, "none", "none")
  }

  func sideEffectClassFor(_ sideEffects: IntentDescriptor.SideEffects) -> String {
    if sideEffects.ptyInput { return "ptyInput" }
    if sideEffects.lifecycle { return "lifecycle" }
    if sideEffects.clipboard { return "clipboard" }
    if sideEffects.filesystem { return "filesystem" }
    if sideEffects.network { return "network" }
    return "none"
  }

  func computeSHA256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  func revalidateLazyAttachContext(
    _ context: ControlAttachApprovalContext,
    clientFD: Int32,
    body: Data
  ) -> Bool {
    guard let currentPID = Self.peerPID(clientFD: clientFD) else { return false }
    guard currentPID == context.peerPID else { return false }
    guard var peerIdentity = processTreeInspector.identity(for: currentPID),
      let startTime = peerIdentity.startTime
    else { return false }
    guard startTime == context.peerStartTime else { return false }
    if let auditToken = context.auditToken {
      peerIdentity.auditToken = auditToken
    }

    guard let (sessionID, shell) = resolveUniqueShellSessionAncestor(peerPID: currentPID),
      sessionID == context.sessionID
    else { return false }

    guard
      let chain = resolveAttachProcessChain(
        peerPID: currentPID,
        shellPID: shell.shellPID,
        peerIdentity: peerIdentity)
    else { return false }
    guard let principal = chain.principal,
      let principalStartTime = principal.identity.startTime
    else { return false }
    var revalidatedIdentity = principal.identity
    if revalidatedIdentity.pid == currentPID {
      revalidatedIdentity.auditToken = context.auditToken
    }
    if let signing = codeSigningInspector.signingIdentity(
      forLivePID: principal.identity.pid,
      startTime: principalStartTime,
      auditToken: revalidatedIdentity.auditToken)
    {
      revalidatedIdentity.signing = signing
    }
    guard revalidatedIdentity.fingerprint == context.principalFingerprint else { return false }

    let computedHash = body.isEmpty ? nil : computeSHA256(body)
    guard computedHash == context.bodySHA256 else { return false }

    let (
      resolvedRouteID,
      resolvedIntentID,
      resolvedCapability,
      resolvedSensitivity,
      resolvedSideEffect
    ) = resolveRouteAndIntent(
      method: context.method,
      path: context.path,
      query: Self.parseQueryString(context.query),
      body: body,
      sessionID: sessionID)
    guard resolvedRouteID == context.resolvedRouteID,
      resolvedIntentID == context.resolvedIntentID,
      resolvedCapability.map({ context.capabilities.contains($0) }) == true,
      resolvedSensitivity == context.maxDataSensitivity,
      resolvedSideEffect == context.allowedSideEffectClasses.first
    else { return false }

    return true
  }

  func lazyAttachResponse(
    sessionID: String,
    approval: String,
    downstream: ControlResponse
  ) -> ControlResponse {
    let bodyString = String(data: downstream.body, encoding: .utf8) ?? ""
    let payload: [String: Any] = [
      "ok": true,
      "sessionID": sessionID,
      "approval": approval,
      "downstreamStatus": downstream.status,
      "downstreamBody": bodyString,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else {
      return .error(500, "internal error")
    }
    return ControlResponse(
      status: 200,
      contentType: "application/json",
      body: data)
  }

  func reportLazyAttachDeny(
    sessionID: String?,
    reason: String
  ) {
    let context = ControlSecurityContext(
      intentID: "control.attach.request",
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachDeny(context, reason: .forbiddenScope)
  }

  func reportLazyAttachApproved(
    sessionID: String,
    approvalID: String,
    intentID: String,
    mode: String
  ) {
    let context = ControlSecurityContext(
      intentID: intentID,
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachApprove(context, mode: mode)
  }

  func reportLazyAttachAutoApproved(
    sessionID: String,
    approvalID: String,
    intentID: String
  ) {
    let context = ControlSecurityContext(
      intentID: intentID,
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachAutoApprove(context, approvalID: approvalID)
  }

  func reportLazyAttachRequest(
    sessionID: String,
    intentID: String
  ) {
    let context = ControlSecurityContext(
      intentID: intentID,
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachRequest(context)
  }
}
