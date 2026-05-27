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
    .executable(name: "laband", targets: ["Laband"]),
    .executable(name: "labpty", targets: ["Labpty"]),
    .executable(name: "find-perf", targets: ["FindPerf"]),
    .executable(name: "bench-pty-drain", targets: ["BenchPtyDrain"]),
    .executable(name: "bench-keystroke-latency", targets: ["BenchKeystrokeLatency"]),
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
      name: "Laband",
      dependencies: ["LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore"]
    ),
    .executableTarget(
      name: "Labpty",
      dependencies: ["LabanTerminalCore"],
      cSettings: [
        .unsafeFlags(["-Wall", "-Wextra", "-Wpedantic", "-Werror"])
      ]
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
    .executableTarget(
      name: "BenchKeystrokeLatency",
      dependencies: ["LabanCore", "LabanRenderer", "LabanTerminalCore"],
      path: "Tools/KeystrokeLatencyBench"
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
      dependencies: ["LabanDebug", "Laband"]
    ),
    .testTarget(
      name: "LabandTests",
      dependencies: ["LabanCore", "LabanTerminalCore"]
    ),
    .testTarget(
      name: "LabptyTests",
      dependencies: ["LabanCore", "Labpty"]
    ),
    .testTarget(
      name: "LabanAppTests",
      dependencies: ["LabanApp", "Laband", "Labpty"],
      exclude: ["Fixtures"]
    ),
  ]
)
