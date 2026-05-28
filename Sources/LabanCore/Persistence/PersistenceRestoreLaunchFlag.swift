import Foundation

public enum PersistenceRestoreLaunchFlag {
  public static let noRestoreArgument = "--no-persistence-restore"
  public static let noPersistenceArgument = "--no-persistence"
  public static let noSyncArgument = noPersistenceArgument
  public static let argument = noRestoreArgument

  public static func isPresent(in arguments: [String] = CommandLine.arguments) -> Bool {
    disablesPersistenceRestore(in: arguments)
  }

  public static func disablesPersistenceRestore(
    in arguments: [String] = CommandLine.arguments
  ) -> Bool {
    let flags = arguments.dropFirst()
    return flags.contains(noRestoreArgument) || flags.contains(noSyncArgument)
  }

  public static func disablesPersistenceSync(
    in arguments: [String] = CommandLine.arguments
  ) -> Bool {
    arguments.dropFirst().contains(noSyncArgument)
  }
}
