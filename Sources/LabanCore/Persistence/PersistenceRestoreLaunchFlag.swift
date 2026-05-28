import Foundation

public enum PersistenceRestoreLaunchFlag {
  public static let noRestoreArgument = "--no-persistence-restore"
  public static let noPersistenceArgument = "--no-persistence"
  public static let noSyncArgument = noPersistenceArgument
  public static let argument = noRestoreArgument
  /// Set by `AppDelegate.restartApp()` on the spawned successor so the
  /// new process knows the prior instance asked for a restart. Used to
  /// suppress the Shift-held workspace-archive escape hatch when the
  /// restart shortcut (⌘⇧⌥R) leaves Shift held at launch — the keybind
  /// chord would otherwise be indistinguishable from a manual
  /// Shift-launch and silently wipe the workspace.
  public static let restartArgument = "--restart"

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

  public static func isAppRestart(
    in arguments: [String] = CommandLine.arguments
  ) -> Bool {
    arguments.dropFirst().contains(restartArgument)
  }
}
