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
    .executable(name: "find-perf", targets: ["FindPerf"]),
    .executable(name: "bench-pty-drain", targets: ["BenchPtyDrain"]),
  ],
  targets: [
    .target(
      name: "LabanTerminalCore",
      publicHeadersPath: "include",
      cSettings: [
        .unsafeFlags(["-I\(_vtInclude)"])
      ],
      linkerSettings: [
        .unsafeFlags(["\(_vtLib)/libghostty-vt.a"])
      ]
    ),
    .target(
      name: "LabanRenderer",
      dependencies: [],
      resources: [
        .copy("Resources/JetBrainsMono-Regular.ttf"),
        .copy("Resources/JetBrainsMono-OFL.txt"),
        .process("Shaders.metal"),
      ]
    ),
    .target(
      name: "LabanCore",
      dependencies: ["LabanTerminalCore", "LabanRenderer"]
    ),
    .target(
      name: "LabanDebug",
      dependencies: ["LabanCore", "LabanRenderer", "LabanTerminalCore"]
    ),
    .executableTarget(
      name: "LabanApp",
      dependencies: ["LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore"],
      resources: [.copy("Resources/AppIcon.icns")]
    ),
    .executableTarget(
      name: "LabanAgent",
      dependencies: ["LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore"]
    ),
    .executableTarget(
      name: "FindPerf",
      dependencies: ["LabanCore", "LabanTerminalCore"],
      path: "Tools/FindPerf"
    ),
    .executableTarget(
      name: "BenchPtyDrain",
      dependencies: ["LabanTerminalCore", "LabanCore"],
      path: "Tools/BenchPtyDrain"
    ),
    .testTarget(
      name: "LabanTerminalCoreTests",
      dependencies: ["LabanTerminalCore"]
    ),
    .testTarget(
      name: "LabanCoreTests",
      dependencies: ["LabanCore", "LabanTerminalCore", "LabanRenderer"]
    ),
    .testTarget(
      name: "LabanRendererTests",
      dependencies: ["LabanRenderer"]
    ),
    .testTarget(
      name: "LabanDebugTests",
      dependencies: ["LabanDebug"]
    ),
    .testTarget(
      name: "LabanAppTests",
      dependencies: ["LabanApp"],
      exclude: ["Fixtures"]
    ),
  ]
)
