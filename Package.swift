// swift-tools-version: 5.9
import Foundation
import PackageDescription

let _pkgDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let _vtInclude = "\(_pkgDir)/.external/libghostty-vt/zig-out/include"
let _vtLib = "\(_pkgDir)/.external/libghostty-vt/zig-out/lib"

let package = Package(
  name: "Laban",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "LabanCore", targets: ["LabanCore"]),
    .library(name: "LabanRenderer", targets: ["LabanRenderer"]),
    .library(name: "LabanDebug", targets: ["LabanDebug"]),
    .executable(name: "LabanApp", targets: ["LabanApp"]),
    .executable(name: "laban-agent", targets: ["LabanAgent"]),
  ],
  targets: [
    .target(
      name: "LabanTerminalCore",
      publicHeadersPath: "include",
      cSettings: [
        .unsafeFlags(["-I\(_vtInclude)"])
      ],
      linkerSettings: [
        .unsafeFlags(["\(_vtLib)/libghostty-vt.a", "-lc++"])
      ]
    ),
    .target(
      name: "LabanRenderer",
      dependencies: []
    ),
    .target(
      name: "LabanCore",
      dependencies: ["LabanTerminalCore", "LabanRenderer"]
    ),
    .target(
      name: "LabanDebug",
      dependencies: ["LabanCore", "LabanRenderer"]
    ),
    .executableTarget(
      name: "LabanApp",
      dependencies: ["LabanCore", "LabanRenderer", "LabanDebug"]
    ),
    .executableTarget(
      name: "LabanAgent",
      dependencies: ["LabanCore", "LabanRenderer", "LabanDebug"]
    ),
    .testTarget(
      name: "LabanTerminalCoreTests",
      dependencies: ["LabanTerminalCore"]
    ),
    .testTarget(
      name: "LabanCoreTests",
      dependencies: ["LabanCore", "LabanTerminalCore"]
    ),
    .testTarget(
      name: "LabanRendererTests",
      dependencies: ["LabanRenderer"]
    ),
    .testTarget(
      name: "LabanDebugTests",
      dependencies: ["LabanDebug"]
    ),
  ]
)
