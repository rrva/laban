import Foundation
import ServiceManagement

enum LabandServiceManagementInstaller {
  static let launchAgentPlistName = "dev.laban.laband.plist"

  static func service(plistName: String = launchAgentPlistName) -> SMAppService {
    SMAppService.agent(plistName: plistName)
  }

  static func status(plistName: String = launchAgentPlistName) -> SMAppService.Status {
    service(plistName: plistName).status
  }

  static func register(plistName: String = launchAgentPlistName) throws {
    try service(plistName: plistName).register()
  }

  static func unregister(plistName: String = launchAgentPlistName) async throws {
    try await service(plistName: plistName).unregister()
  }
}
