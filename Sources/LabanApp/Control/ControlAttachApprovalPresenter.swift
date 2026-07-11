import AppKit
import LabanControl
import LabanCore

/// Pure, testable content for the adaptive "Can/Cannot" family dialog
/// (dialog-redesign-brief, 2026-07-11). Every field is a plain string or SF
/// Symbol name so a test can assert the exact wording and icon choice without
/// driving `NSAlert`/`NSView`. `ControlAttachApprovalPresenter.dialogContent(for:)`
/// builds this; `makeAdaptiveDetailsView` renders it.
struct ApprovalDialogContent {
  var title: String
  var subhead: String
  var subheadIsWarning: Bool
  var can: String
  var cannot: String
  /// Bold lead-in word before `can`/`cannot` so the exclusion line cannot be
  /// misread as a grant at a glance (the icon alone is too subtle a signal for
  /// a consent decision).
  var canLeadIn: String
  var cannotLeadIn: String
  var canSymbolName: String
  var cannotSymbolName: String
  var scope: String
  /// Shown always, prominent, not de-emphasized. Populated only for an
  /// unverified principal, where Path/Chain/Operation ARE the decision.
  var inlineRows: [(String, String)]
  /// The forensic/anti-spoof rows (Requester, Path, Chain, Operation) for a
  /// verified principal, where the code signature is the trust anchor and
  /// these rows start de-emphasized rather than being the primary read.
  var detailRows: [(String, String)]
  /// True when `detailRows` is the collapsed-by-default set (verified
  /// principal). The renderer hides those rows behind a real disclosure
  /// triangle, collapsed by default, so a verified-app user reads only title,
  /// Can, Cannot, Scope, and buttons unless they choose to expand.
  var showsDisclosure: Bool
}

/// A disclosure triangle that owns its toggle closure, so the collapse control
/// needs no presenter state or associated objects: the button lives in the
/// alert's accessory view hierarchy and retains the closure for as long as the
/// dialog is on screen.
private final class DisclosureToggleButton: NSButton {
  private var onToggle: (() -> Void)?

  func configureToggle(_ onToggle: @escaping () -> Void) {
    self.onToggle = onToggle
    target = self
    action = #selector(handleToggle)
  }

  @objc private func handleToggle() {
    onToggle?()
  }
}

final class ControlAttachApprovalPresenter: ControlAttachApprovalDelegate, @unchecked Sendable {
  static let shared = ControlAttachApprovalPresenter()

  /// The alert button titles this presenter would construct for `request`,
  /// in the order they are added to the alert (first button ==
  /// `alertFirstButtonReturn`). Factored out of `presentOnMain` so button
  /// presence/order is unit-testable without driving `NSAlert`/`NSApp`.
  static func buttonTitles(for request: ControlAttachApprovalRequest) -> [String] {
    var titles = ["Allow Once"]
    if request.canPersist {
      titles.append("Always Allow")
    }
    titles.append("Deny")
    return titles
  }

  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    DispatchQueue.main.async {
      self.presentOnMain(request: request, completion: completion)
    }
  }

  private func presentOnMain(
    request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning

    if request.grantsSessionReadFamily {
      // The redesigned "Adaptive Can/Cannot" dialog (dialog-redesign-brief,
      // 2026-07-11): every real lazy approval produces a family grant now, so
      // this is the path that matters for cognitive load.
      let content = Self.dialogContent(for: request)
      alert.messageText = content.title
      alert.accessoryView = makeAdaptiveDetailsView(for: content, request: request, alert: alert)
    } else if request.dataSensitivity == "screenshot" {
      let content = Self.windowScreenshotDialogContent(for: request)
      alert.messageText = content.title
      alert.accessoryView = makeAdaptiveDetailsView(for: content, request: request, alert: alert)
    } else {
      // Legacy, request-exact grant: still used by tests and defensively.
      // Keep the pre-redesign single-grant row layout; do not invent
      // Can/Cannot text for a single-operation grant.
      // "Observe", not "control": every capability this dialog can grant is
      // read-only (read state/session, propose a command for review). It
      // cannot type, click, paste, or otherwise drive the terminal. Saying
      // "control" here misrepresents an observe-only permission as actuation.
      if request.principalIsVerified {
        alert.messageText = "Allow \(request.principalDisplayName) to observe this Laban session?"
        alert.informativeText = "A verified app is asking for one session-scoped read permission."
      } else {
        alert.messageText =
          "Allow unverified \(request.principalDisplayName) to observe this Laban session?"
        alert.informativeText =
          "Only allow this if you recognize the app and the path shown below."
      }
      alert.accessoryView = makeDetailsView(for: request)
    }

    let canAlwaysAllow = request.canPersist
    for title in Self.buttonTitles(for: request) {
      alert.addButton(withTitle: title)
    }

    let finish: (NSApplication.ModalResponse) -> Void = { response in
      switch response {
      case .alertFirstButtonReturn:
        completion(.allowOnce)
      case .alertSecondButtonReturn:
        if canAlwaysAllow {
          completion(.alwaysAllowSignedIdentity)
        } else {
          completion(.deny)
        }
      default:
        completion(.deny)
      }
    }

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: window) { response in
        finish(response)
      }
    } else {
      finish(alert.runModal())
    }
  }

  /// The wording this alert's fixed-title rows a name (before Scope's dynamic
  /// suffix and the optional persistence-disabled note) render for `request`,
  /// in the order `makeDetailsView` arranges them. Factored out so the
  /// Data/Proposes/Not-included wording is unit-testable without driving
  /// `NSStackView`/`NSAlert` (mirrors `buttonTitles(for:)`).
  ///
  /// A family grant (`request.grantsSessionReadFamily`) describes the whole
  /// own-session read family, content-inclusive, names the propose grant
  /// (review NOTE 2), and adds a "Not included" row. A non-family (legacy,
  /// request-exact) grant keeps the single-sensitivity Data row unchanged and
  /// has no "Not included" row.
  static func detailRows(for request: ControlAttachApprovalRequest) -> [(String, String)] {
    var rows: [(String, String)] = [
      ("Operation", shortOperationSummary(request.operationSummary)),
      ("Session", request.sessionDisplay),
      ("Requester", request.principalDisplayName),
    ]
    if let path = request.principalPath, !path.isEmpty {
      rows.append(("Path", compactPath(path)))
    }
    rows.append(("Chain", request.helperChainSummary))
    if request.grantsSessionReadFamily {
      rows.append(
        (
          "Data",
          "This session's screen text, scrollback, and selection, "
            + "and may suggest commands for your review"
        ))
    } else {
      rows.append(("Data", readableDataSensitivity(request.dataSensitivity)))
    }
    if !request.capabilities.isEmpty {
      rows.append(("Permission", readableCapabilities(request.capabilities)))
    }
    rows.append(
      (
        "Scope",
        request.canPersist ? "This app in this Laban session" : "This request only"
      ))
    if request.grantsSessionReadFamily {
      rows.append(
        ("Not included", "No keyboard input, clipboard, tab switching, or other sessions."))
    }
    return rows
  }

  /// The adaptive "Can/Cannot" content for a family grant
  /// (`request.grantsSessionReadFamily`), the redesign this presenter targets
  /// (dialog-redesign-brief, 2026-07-11). Pure and testable: strings and SF
  /// Symbol names only, no `NSView`. Only called for family requests; the
  /// non-family (legacy, request-exact) path keeps `detailRows(for:)` and the
  /// pre-redesign row layout unchanged.
  ///
  /// A verified principal's code signature is the trust anchor, so the
  /// forensic rows (Requester, Path, Chain, Operation) start behind the
  /// disclosure. An unverified principal has no such anchor, so Path, Chain,
  /// and Operation ARE the decision and render inline instead.
  ///
  /// Both variants share one Can and one Cannot line, fixing the tabs
  /// contradiction the redesign was asked to fix: the old Permission row said
  /// "Navigate tabs and viewport" while the old Not-included row said "No tab
  /// switching". The family's `.navigate` capability is own-session
  /// `terminal.scrollViewport` only, never tab navigation (invariant I7), so
  /// Cannot now says "switch tabs" unconditionally and Can never mentions
  /// "tab".
  static func dialogContent(for request: ControlAttachApprovalRequest) -> ApprovalDialogContent {
    let can =
      "Read this session's screen, scrollback, and selection; scroll its viewport; "
      + "and suggest commands for your review."
    let cannot = "Type, paste, switch tabs, or reach other sessions."
    let scope = request.canPersist ? "This app in this Laban session" : "This request only"
    let operation = ("Operation", shortOperationSummary(request.operationSummary))
    let chain = ("Chain", request.helperChainSummary)
    let path: (String, String)? =
      request.principalPath.flatMap { $0.isEmpty ? nil : ("Path", compactPath($0)) }

    var inlineRows: [(String, String)] = []
    var detailRows: [(String, String)] = []
    let title: String
    let subhead: String
    let subheadIsWarning: Bool

    if request.principalIsVerified {
      title = "Allow \(request.principalDisplayName) to read this session?"
      subhead = "Verified app - session \(request.sessionDisplay)"
      subheadIsWarning = false
      // No Requester row: it would exactly duplicate the title. The forensic
      // rows a verified-app user might still want are Path, Chain, and the
      // triggering Operation.
      if let path { detailRows.append(path) }
      detailRows.append(chain)
      detailRows.append(operation)
    } else {
      title = "Allow unverified \(request.principalDisplayName) to read this session?"
      subhead = "Not a verified app - check the path and chain below before allowing."
      subheadIsWarning = true
      if let path { inlineRows.append(path) }
      inlineRows.append(chain)
      inlineRows.append(operation)
    }

    return ApprovalDialogContent(
      title: title,
      subhead: subhead,
      subheadIsWarning: subheadIsWarning,
      can: can,
      cannot: cannot,
      canLeadIn: "Can",
      cannotLeadIn: "Cannot",
      canSymbolName: "eye",
      cannotSymbolName: "hand.raised",
      scope: scope,
      inlineRows: inlineRows,
      detailRows: detailRows,
      showsDisclosure: !detailRows.isEmpty)
  }

  static func windowScreenshotDialogContent(
    for request: ControlAttachApprovalRequest
  ) -> ApprovalDialogContent {
    let can =
      "Capture the visible Laban window, including its title bar, sidebar, sheets, and dialogs."
    let cannot = "Read hidden tabs, type, paste, or control Laban."
    let scope = request.canPersist ? "This app in this Laban session" : "This request only"
    let operation = ("Operation", shortOperationSummary(request.operationSummary))
    let chain = ("Chain", request.helperChainSummary)
    let path: (String, String)? =
      request.principalPath.flatMap { $0.isEmpty ? nil : ("Path", compactPath($0)) }

    var inlineRows: [(String, String)] = []
    var detailRows: [(String, String)] = []
    let title: String
    let subhead: String
    let subheadIsWarning: Bool
    if request.principalIsVerified {
      title = "Allow \(request.principalDisplayName) to capture this Laban window?"
      subhead = "Verified app - session \(request.sessionDisplay)"
      subheadIsWarning = false
      if let path { detailRows.append(path) }
      detailRows.append(chain)
      detailRows.append(operation)
    } else {
      title = "Allow unverified \(request.principalDisplayName) to capture this Laban window?"
      subhead = "Not a verified app - check the path and chain below before allowing."
      subheadIsWarning = true
      if let path { inlineRows.append(path) }
      inlineRows.append(chain)
      inlineRows.append(operation)
    }

    return ApprovalDialogContent(
      title: title,
      subhead: subhead,
      subheadIsWarning: subheadIsWarning,
      can: can,
      cannot: cannot,
      canLeadIn: "Can",
      cannotLeadIn: "Cannot",
      canSymbolName: "camera.viewfinder",
      cannotSymbolName: "hand.raised",
      scope: scope,
      inlineRows: inlineRows,
      detailRows: detailRows,
      showsDisclosure: !detailRows.isEmpty)
  }

  private func makeDetailsView(for request: ControlAttachApprovalRequest) -> NSView {
    let detailsWidth = Self.detailsWidth
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = true
    stack.setFrameSize(NSSize(width: detailsWidth, height: 1))

    for (title, value) in Self.detailRows(for: request) {
      let monospaced = title == "Path"
      stack.addArrangedSubview(
        detailRow(
          title, value,
          tooltip: monospaced ? request.principalPath : nil,
          monospaced: monospaced,
          rowWidth: detailsWidth))
    }
    if !request.canPersist, let reason = request.persistenceDisabledReason {
      let note = NSTextField(wrappingLabelWithString: "Always Allow is unavailable: \(reason)")
      note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      note.textColor = .secondaryLabelColor
      note.maximumNumberOfLines = 2
      note.translatesAutoresizingMaskIntoConstraints = false
      note.widthAnchor.constraint(equalToConstant: detailsWidth).isActive = true
      stack.addArrangedSubview(note)
    }

    stack.layoutSubtreeIfNeeded()
    stack.setFrameSize(NSSize(width: detailsWidth, height: ceil(stack.fittingSize.height)))
    return stack
  }

  private func detailRow(
    _ title: String,
    _ value: String,
    tooltip: String? = nil,
    monospaced: Bool = false,
    rowWidth: CGFloat
  ) -> NSView {
    let titleField = NSTextField(labelWithString: title)
    titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    titleField.textColor = .secondaryLabelColor
    titleField.alignment = .right
    titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
    titleField.translatesAutoresizingMaskIntoConstraints = false

    let valueField =
      monospaced
      ? NSTextField(labelWithString: value)
      : NSTextField(wrappingLabelWithString: value)
    valueField.font =
      monospaced
      ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
      : .systemFont(ofSize: NSFont.systemFontSize)
    valueField.lineBreakMode = monospaced ? .byTruncatingMiddle : .byWordWrapping
    valueField.maximumNumberOfLines = monospaced ? 1 : 3
    valueField.toolTip = tooltip
    valueField.isSelectable = true
    valueField.translatesAutoresizingMaskIntoConstraints = false
    valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [titleField, valueField])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      titleField.widthAnchor.constraint(equalToConstant: 76),
      row.widthAnchor.constraint(equalToConstant: rowWidth),
    ])
    return row
  }

  /// Renders `content` (from `dialogContent(for:)`) as the family dialog's
  /// accessory view: subhead, then (unverified only) the inline forensic
  /// rows, then the Can/Cannot lines, then (verified only) the de-emphasized
  /// detail rows, then the always-visible Scope row.
  ///
  /// A verified principal's forensic rows (Path, Chain, Operation) live behind
  /// a real disclosure triangle, collapsed by default: the verified-app user
  /// reads only title, subhead, Can, Cannot, Scope, and buttons unless they
  /// click "Details" to expand. Toggling flips the sub-stack's `isHidden`,
  /// relays out, and calls `alert.layout()` so the sheet grows or shrinks to
  /// fit. An unverified principal has no disclosure: its Path/Chain/Operation
  /// render inline and prominent (those rows ARE the decision).
  private func makeAdaptiveDetailsView(
    for content: ApprovalDialogContent,
    request: ControlAttachApprovalRequest,
    alert: NSAlert
  ) -> NSView {
    let detailsWidth = Self.detailsWidth
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = true
    stack.setFrameSize(NSSize(width: detailsWidth, height: 1))

    let subheadField = NSTextField(wrappingLabelWithString: content.subhead)
    subheadField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    // Warning subhead uses systemOrange (attention, not systemRed's "error"
    // register): an unverified principal is a decision point, not a failure.
    subheadField.textColor = content.subheadIsWarning ? .systemOrange : .secondaryLabelColor
    subheadField.maximumNumberOfLines = 2
    subheadField.translatesAutoresizingMaskIntoConstraints = false
    subheadField.widthAnchor.constraint(equalToConstant: detailsWidth).isActive = true
    stack.addArrangedSubview(subheadField)

    // Unverified only: Path/Chain/Operation are prominent and inline because
    // for an unverified app these ARE the decision, not a disclosure.
    for (title, value) in content.inlineRows {
      let monospaced = title == "Path"
      stack.addArrangedSubview(
        detailRow(
          title, value,
          tooltip: monospaced ? request.principalPath : nil,
          monospaced: monospaced,
          rowWidth: detailsWidth))
    }

    stack.addArrangedSubview(
      canCannotRow(
        symbolName: content.canSymbolName, leadIn: content.canLeadIn, text: content.can,
        tint: .controlAccentColor, rowWidth: detailsWidth))
    let cannotRow = canCannotRow(
      symbolName: content.cannotSymbolName, leadIn: content.cannotLeadIn, text: content.cannot,
      tint: .secondaryLabelColor, rowWidth: detailsWidth)
    stack.addArrangedSubview(cannotRow)
    // Generous rhythm: a little more room after the Can/Cannot block than the
    // uniform 8pt stack spacing elsewhere, whatever follows (Scope directly
    // for an unverified principal, or the de-emphasized details block for a
    // verified one).
    stack.setCustomSpacing(16, after: cannotRow)

    if !content.detailRows.isEmpty {
      // The forensic rows collapse behind a disclosure triangle, hidden by
      // default. A verified-app user does not need to read them to decide; the
      // code signature is the trust anchor and the Can/Cannot lines carry the
      // decision.
      let detailsStack = NSStackView()
      detailsStack.orientation = .vertical
      detailsStack.alignment = .leading
      detailsStack.spacing = 8
      detailsStack.translatesAutoresizingMaskIntoConstraints = false
      detailsStack.isHidden = true
      for (title, value) in content.detailRows {
        let monospaced = title == "Path"
        let row = detailRow(
          title, value,
          tooltip: monospaced ? request.principalPath : nil,
          monospaced: monospaced,
          rowWidth: detailsWidth)
        detailsStack.addArrangedSubview(row)
      }

      // A borderless "chevron + Details" toggle, not an NSButton with
      // `bezelStyle = .disclosure`: that bezel is a triangle-only control that
      // clips a text title to one glyph ("D") and reads as noise, not an
      // affordance. A leading SF Symbol chevron that flips right/down plus the
      // word "Details" is an unmistakable, native show-more control.
      let disclosure = DisclosureToggleButton()
      disclosure.title = "Details"
      disclosure.imagePosition = .imageLeading
      disclosure.image = Self.chevronImage(expanded: false)
      disclosure.isBordered = false
      disclosure.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
      disclosure.contentTintColor = .secondaryLabelColor
      disclosure.translatesAutoresizingMaskIntoConstraints = false
      disclosure.configureToggle { [weak stack, weak detailsStack, weak alert, weak disclosure] in
        guard let stack, let detailsStack, let alert else { return }
        let nowExpanded = detailsStack.isHidden
        detailsStack.isHidden.toggle()
        disclosure?.image = Self.chevronImage(expanded: nowExpanded)
        Self.resizeAccessory(stack, width: detailsWidth, alert: alert)
      }

      stack.addArrangedSubview(disclosure)
      stack.addArrangedSubview(detailsStack)
      detailsStack.widthAnchor.constraint(equalToConstant: detailsWidth).isActive = true
    }

    let scopeField = NSTextField(wrappingLabelWithString: content.scope)
    scopeField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    scopeField.textColor = .secondaryLabelColor
    scopeField.maximumNumberOfLines = 2
    scopeField.translatesAutoresizingMaskIntoConstraints = false
    scopeField.widthAnchor.constraint(equalToConstant: detailsWidth).isActive = true
    stack.addArrangedSubview(scopeField)

    if !request.canPersist, let reason = request.persistenceDisabledReason {
      let note = NSTextField(wrappingLabelWithString: "Always Allow is unavailable: \(reason)")
      note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      note.textColor = .secondaryLabelColor
      note.maximumNumberOfLines = 2
      note.translatesAutoresizingMaskIntoConstraints = false
      note.widthAnchor.constraint(equalToConstant: detailsWidth).isActive = true
      stack.addArrangedSubview(note)
    }

    Self.resizeAccessory(stack, width: detailsWidth, alert: alert)
    return stack
  }

  /// Re-measures `stack` after its contents change (a disclosure toggle shows
  /// or hides rows) and grows or shrinks the alert to fit. The accessory stack
  /// manages its own frame (`translatesAutoresizingMaskIntoConstraints`), so
  /// the height must be recomputed by hand; `alert.layout()` then reflows the
  /// sheet around the new accessory size.
  private static func resizeAccessory(_ stack: NSStackView, width: CGFloat, alert: NSAlert) {
    stack.layoutSubtreeIfNeeded()
    stack.setFrameSize(NSSize(width: width, height: ceil(stack.fittingSize.height)))
    alert.layout()
  }

  /// The disclosure chevron for the "Details" toggle: `chevron.down` when the
  /// rows are expanded, `chevron.right` when collapsed, matching the native
  /// show-more idiom. Degrades to no image (text-only "Details") if the symbol
  /// is unavailable, never crashes.
  private static func chevronImage(expanded: Bool) -> NSImage? {
    let name = expanded ? "chevron.down" : "chevron.right"
    let image = NSImage(
      systemSymbolName: name,
      accessibilityDescription: expanded ? "Hide details" : "Show details")
    let configuration = NSImage.SymbolConfiguration(
      pointSize: NSFont.smallSystemFontSize, weight: .semibold)
    return image?.withSymbolConfiguration(configuration)
  }

  /// One Can/Cannot line: a leading SF Symbol (aligned to a fixed-width
  /// column) plus a bold `leadIn` word ("Can"/"Cannot") and body text. The
  /// lead-in makes the exclusion line unmistakably negative at a glance, so it
  /// cannot be misread as a grant. No macOS-26-only symbol or configuration API
  /// is used here (`NSImage.SymbolConfiguration(pointSize:weight:scale:)` and
  /// `NSImage(systemSymbolName:accessibilityDescription:)` exist since macOS
  /// 11, well under this package's .v13 floor), so no `#available` gate is
  /// needed for this call; if the named symbol is missing on the running OS
  /// the initializer returns `nil` and the row degrades to text only, never
  /// crashes.
  private func canCannotRow(
    symbolName: String,
    leadIn: String,
    text: String,
    tint: NSColor,
    rowWidth: CGFloat
  ) -> NSView {
    var arranged: [NSView] = []
    if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
      let configuration = NSImage.SymbolConfiguration(
        pointSize: NSFont.systemFontSize, weight: .regular)
      let imageView = NSImageView()
      imageView.image = symbolImage.withSymbolConfiguration(configuration)
      if #available(macOS 10.14, *) {
        imageView.contentTintColor = tint
      }
      imageView.translatesAutoresizingMaskIntoConstraints = false
      imageView.widthAnchor.constraint(equalToConstant: 20).isActive = true
      imageView.setContentHuggingPriority(.required, for: .horizontal)
      arranged.append(imageView)
    }

    // Bold "Can: " / "Cannot: " lead-in, then the body at regular weight, in
    // one attributed string so they wrap as a single paragraph.
    let bodySize = NSFont.systemFontSize
    let attributed = NSMutableAttributedString(
      string: "\(leadIn): ",
      attributes: [
        .font: NSFont.boldSystemFont(ofSize: bodySize),
        .foregroundColor: NSColor.labelColor,
      ])
    attributed.append(
      NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.systemFont(ofSize: bodySize),
          .foregroundColor: NSColor.labelColor,
        ]))
    let textField = NSTextField(labelWithAttributedString: attributed)
    textField.maximumNumberOfLines = 4
    textField.lineBreakMode = .byWordWrapping
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    arranged.append(textField)

    let row = NSStackView(views: arranged)
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
    return row
  }

  private static let detailsWidth: CGFloat = 360

  private static func shortOperationSummary(_ summary: String) -> String {
    let withoutParenthetical = summary.replacingOccurrences(
      of: #"\s*\([^)]*\)"#,
      with: "",
      options: .regularExpression)
    return withoutParenthetical.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
  }

  private static func compactPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
      return "~"
    }
    if path.hasPrefix(home + "/") {
      return "~" + String(path.dropFirst(home.count))
    }
    return path
  }

  private static func readableDataSensitivity(_ raw: String) -> String {
    switch raw {
    case "none": return "None"
    case "nonSensitiveState": return "Basic app state"
    case "visibleText": return "Visible terminal text"
    case "scrollback": return "Scrollback"
    case "keystrokes": return "Keystrokes"
    case "clipboard": return "Clipboard"
    case "screenshot": return "Screenshot"
    case "trace": return "Trace data"
    case "sensitivePrivate": return "Private session data"
    default: return raw
    }
  }

  private static func readableCapabilities(_ capabilities: [String]) -> String {
    capabilities.map(readableCapability).joined(separator: ", ")
  }

  /// Not `private`: unit-tested directly (`testReadableCapabilityNavigate...`)
  /// so the tabs-contradiction bug in the "navigate" case cannot regress
  /// silently, mirroring `buttonTitles(for:)`/`detailRows(for:)`'s visibility.
  static func readableCapability(_ raw: String) -> String {
    switch raw {
    case "observe": return "Read app state"
    case "observeSensitive": return "Read private session state"
    // The family's `.navigate` capability is own-session
    // `terminal.scrollViewport` only, never tab navigation (invariant I7
    // pins the gui `.navigate` set to exactly {terminal.scrollViewport}).
    // "Navigate tabs and viewport" was wrong: it contradicted the family
    // dialog's own "No tab switching" line (dialog-redesign-brief,
    // 2026-07-11).
    case "navigate": return "Scroll this session's viewport"
    case "propose": return "Propose commands"
    case "input": return "Send input"
    case "fixture": return "Use fixture controls"
    default: return raw
    }
  }
}
