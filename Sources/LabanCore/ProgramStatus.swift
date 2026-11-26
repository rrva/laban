import Foundation

/// OSC 7501, the Program Status Protocol (spec revision 0.4, 2026-10-10): a
/// program tells the terminal what it is doing — at rest, working, finished,
/// blocked on the user, or failed — with an optional one-line message.
///
/// Wire form: `ESC ] 7501 ; key=value:key=value ST`. The C scanner
/// (`LabanTerminalCore/osc_host.c`) answers the `?` feature query and hands
/// every other payload here unparsed. This file owns validation
/// (`ProgramStatusReport.parse`) and the per-pane record store
/// (`ProgramStatusRecords`); both are pure values.
public enum ProgramStatusState: String, Codable, Equatable, Sendable {
  case idle
  case working
  case done
  case blocked
  case error
}

/// What a `blocked` program is waiting for.
public enum ProgramStatusBlockKind: String, Codable, Equatable, Sendable {
  case permission
  case question
  case auth
}

/// One validated OSC 7501 report.
public struct ProgramStatusReport: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case set(ProgramStatusState)
    /// `state=clear`: remove the addressed record and everything beneath it.
    case clear
  }

  public var action: Action
  /// Record path (`build/test`); empty addresses the root record.
  public var id: String
  public var kind: ProgramStatusBlockKind?
  public var progress: Int?
  public var app: String?
  public var title: String?
  public var message: String?

  public init(
    action: Action, id: String = "", kind: ProgramStatusBlockKind? = nil, progress: Int? = nil,
    app: String? = nil, title: String? = nil, message: String? = nil
  ) {
    self.action = action
    self.id = id
    self.kind = kind
    self.progress = progress
    self.app = app
    self.title = title
    self.message = message
  }

  // Spec limits. A report that breaks one is discarded whole.
  /// 4096 bytes for the whole sequence, less `ESC ] 7501 ;` and a one-byte
  /// terminator.
  static let maxPayloadBytes = 4096 - 8
  static let maxKeyBytes = 16
  static let maxMessageEncodedBytes = 2732
  static let maxMessageBytes = 2048
  static let maxTitleEncodedBytes = 256
  static let maxTitleBytes = 192
  static let maxAppBytes = 32
  static let maxIdBytes = 128
  static let maxIdSegmentBytes = 32
  static let maxIdDepth = 8

  /// Parse the bytes between `7501;` and the terminator. Returns nil for a
  /// report the spec says to ignore or discard: no or unknown `state`, an
  /// invalid `id`, a broken limit, undecodable base64, or a control character
  /// in decoded text. Malformed pairs and unknown keys are skipped; the last
  /// value of a repeated key wins; an invalid `kind`, `progress` or `app` is
  /// treated as absent.
  public static func parse(_ payload: some Sequence<UInt8>) -> ProgramStatusReport? {
    let bytes = Array(payload)
    guard !bytes.isEmpty, bytes.count <= maxPayloadBytes else { return nil }

    var values: [String: [UInt8]] = [:]
    for pair in bytes.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false) {
      guard let eq = pair.firstIndex(of: UInt8(ascii: "=")) else { continue }
      let key = trim(pair[pair.startIndex..<eq])
      let value = trim(pair[pair.index(after: eq)...])
      guard !key.isEmpty, key.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { continue }
      guard key.count <= maxKeyBytes else { return nil }
      guard value.allSatisfy(isValueByte) else {
        // A malformed `id` still names a record: treating it as absent would
        // retarget the report at the root (and a clear at every record).
        if key.elementsEqual("id".utf8) { return nil }
        continue
      }
      values[String(decoding: key, as: UTF8.self)] = Array(value)
    }

    guard let stateBytes = values["state"] else { return nil }
    let stateText = String(decoding: stateBytes, as: UTF8.self)
    let action: Action
    if stateText == "clear" {
      action = .clear
    } else if let state = ProgramStatusState(rawValue: stateText) {
      action = .set(state)
    } else {
      // An unknown state must not degrade to a known one on an older terminal.
      return nil
    }

    var id = ""
    if let raw = values["id"] {
      guard isValidId(raw) else { return nil }
      id = String(decoding: raw, as: UTF8.self)
    }

    var message: String?
    if let raw = values["msg"], !raw.isEmpty {
      guard
        let text = decodeText(
          raw, maxEncoded: maxMessageEncodedBytes, maxDecoded: maxMessageBytes)
      else { return nil }
      message = text.isEmpty ? nil : text
    }
    var title: String?
    if let raw = values["title"], !raw.isEmpty {
      guard let text = decodeText(raw, maxEncoded: maxTitleEncodedBytes, maxDecoded: maxTitleBytes)
      else { return nil }
      title = text.isEmpty ? nil : text
    }

    guard case .set(let state) = action else {
      return ProgramStatusReport(action: .clear, id: id)
    }

    var kind: ProgramStatusBlockKind?
    if state == .blocked, let raw = values["kind"] {
      kind = ProgramStatusBlockKind(rawValue: String(decoding: raw, as: UTF8.self))
    }
    var progress: Int?
    if state == .working || state == .blocked, let raw = values["progress"],
      !raw.isEmpty, raw.count <= 3, raw.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
      let n = Int(String(decoding: raw, as: UTF8.self)), n <= 100
    {
      progress = n
    }
    var app: String?
    if let raw = values["app"], !raw.isEmpty, raw.count <= maxAppBytes,
      raw.allSatisfy(isSegmentByte)
    {
      app = String(decoding: raw, as: UTF8.self)
    }
    return ProgramStatusReport(
      action: action, id: id, kind: kind, progress: progress, app: app, title: title,
      message: message)
  }

  private static func trim(_ s: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
    var s = s
    while let f = s.first, f == 0x20 || f == 0x09 { s = s.dropFirst() }
    while let l = s.last, l == 0x20 || l == 0x09 { s = s.dropLast() }
    return s
  }

  private static func isAlnum(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
  }

  /// `[A-Za-z0-9_.,+/=-]`
  private static func isValueByte(_ b: UInt8) -> Bool {
    isAlnum(b) || b == 0x5F || b == 0x2E || b == 0x2C || b == 0x2B || b == 0x2F || b == 0x3D
      || b == 0x2D
  }

  /// `[A-Za-z0-9_.+-]`, the alphabet of an id segment and of `app`.
  private static func isSegmentByte(_ b: UInt8) -> Bool {
    isAlnum(b) || b == 0x5F || b == 0x2E || b == 0x2B || b == 0x2D
  }

  private static func isValidId(_ raw: [UInt8]) -> Bool {
    guard !raw.isEmpty, raw.count <= maxIdBytes else { return false }
    let segments = raw.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
    guard segments.count <= maxIdDepth else { return false }
    return segments.allSatisfy {
      !$0.isEmpty && $0.count <= maxIdSegmentBytes && $0.allSatisfy(isSegmentByte)
    }
  }

  /// Standard base64 (padding optional) of single-line UTF-8. Returns nil when
  /// the report must be discarded.
  private static func decodeText(_ raw: [UInt8], maxEncoded: Int, maxDecoded: Int) -> String? {
    guard raw.count <= maxEncoded else { return nil }
    var encoded = raw
    while encoded.last == UInt8(ascii: "=") { encoded.removeLast() }
    guard
      encoded.allSatisfy({ isAlnum($0) || $0 == 0x2B || $0 == 0x2F }),
      encoded.count % 4 != 1
    else { return nil }
    encoded.append(contentsOf: repeatElement(UInt8(ascii: "="), count: (4 - encoded.count % 4) % 4))
    guard let data = Data(base64Encoded: Data(encoded)), data.count <= maxDecoded,
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    var cleaned = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      let v = scalar.value
      if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) { return nil }
      // The text is shown outside the terminal grid (sidebar, banners), so
      // disarm text-direction overrides and other invisible formatting. The
      // zero-width joiner and non-joiner stay: emoji and several scripts
      // need them.
      if scalar.properties.generalCategory == .format, v != 0x200C, v != 0x200D { continue }
      cleaned.append(scalar)
    }
    return String(cleaned).trimmingCharacters(in: .whitespaces)
  }
}

/// What a pane stores for one record id: exactly the keys of the last report
/// that addressed it.
public struct ProgramStatusRecord: Codable, Equatable, Sendable {
  /// Record path; empty is the root record.
  public var id: String
  public var state: ProgramStatusState
  public var kind: ProgramStatusBlockKind?
  public var progress: Int?
  public var app: String?
  public var title: String?
  public var message: String?
}

/// The OSC 7501 records of one pane, least recently updated first.
public struct ProgramStatusRecords: Codable, Equatable, Sendable {
  /// Cap on records per pane; the least recently updated record makes room.
  public static let maxRecords = 256

  public private(set) var records: [ProgramStatusRecord] = []

  public init() {}

  public var isEmpty: Bool { records.isEmpty }

  /// Apply one report. Returns whether anything changed.
  @discardableResult
  public mutating func apply(_ report: ProgramStatusReport) -> Bool {
    let before = records
    switch report.action {
    case .clear:
      if report.id.isEmpty {
        records.removeAll()
      } else {
        let prefix = report.id + "/"
        records.removeAll { $0.id == report.id || $0.id.hasPrefix(prefix) }
      }
    case .set(let state):
      // A report replaces its record completely: omitted keys are gone.
      records.removeAll { $0.id == report.id }
      records.append(
        ProgramStatusRecord(
          id: report.id, state: state, kind: report.kind, progress: report.progress,
          app: report.app, title: report.title, message: report.message))
      if records.count > Self.maxRecords {
        records.removeFirst(records.count - Self.maxRecords)
      }
    }
    return records != before
  }

  /// The program exited or the shell drew a new prompt: `working` and
  /// `blocked` cannot outlive the program, and Laban also drops `idle`.
  /// `done` and `error` stay until the user has seen them.
  @discardableResult
  public mutating func dropLiveRecords() -> Bool {
    let before = records.count
    records.removeAll { $0.state == .working || $0.state == .blocked || $0.state == .idle }
    return records.count != before
  }

  /// The user looked at the pane: finished results have been seen.
  @discardableResult
  public mutating func dropSeenResults() -> Bool {
    let before = records.count
    records.removeAll { $0.state == .done || $0.state == .error }
    return records.count != before
  }

  /// `app` of a record, inherited from its nearest ancestor that has one.
  public func effectiveApp(for record: ProgramStatusRecord) -> String? {
    if let app = record.app { return app }
    var path = record.id
    while !path.isEmpty {
      path = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
      if let app = records.last(where: { $0.id == path })?.app { return app }
    }
    return nil
  }

  /// The one record a pane shows when it has room for one: the most urgent
  /// state wins (blocked, then error, working, done, idle), and within a
  /// state the most recently updated. `app` is resolved through inheritance.
  public var summary: ProgramStatusRecord? {
    func rank(_ s: ProgramStatusState) -> Int {
      switch s {
      case .blocked: return 4
      case .error: return 3
      case .working: return 2
      case .done: return 1
      case .idle: return 0
      }
    }
    var best: ProgramStatusRecord?
    for record in records where best.map({ rank(record.state) >= rank($0.state) }) ?? true {
      best = record
    }
    guard var result = best else { return nil }
    result.app = effectiveApp(for: result)
    return result
  }
}
