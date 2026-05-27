import LabanTerminalCore

extension Session {
  public static func parserOnly(size: LabanTerminalSize) throws -> Session {
    try fixture(size: size)
  }
}
