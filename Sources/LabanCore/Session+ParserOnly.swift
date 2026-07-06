import LabanTerminalCore

extension Session {
  public static func parserOnly(size: LabanTerminalSize, sessionID: ID? = nil) throws -> Session {
    try fixture(size: size, sessionID: sessionID)
  }
}
