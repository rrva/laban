// swift-tools-version: 5.9
import Foundation
import PackageDescription

let _pkgDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let _vtInclude = "\(_pkgDir)/.external/libghostty-vt/zig-out/include"
let _vtLib = "\(_pkgDir)/.external/libghostty-vt/zig-out/lib"

// Release builds drop Swift's *runtime* exclusivity checks. Time Profiler showed
// AccessSet::insert + swift_beginAccess at ~5% of main-thread CPU, concentrated
// in the renderer's closure-heavy cell build (captured-var accesses each take a
// dynamic exclusivity check). Static (compile-time) exclusivity enforcement
// still runs; only the dynamic belt-and-suspenders check is removed.
let _releaseExclusivity: [SwiftSetting] = [
  .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))
]

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
    .executable(name: "labpty-dump", targets: ["LabptyDump"]),
    .executable(name: "bench-labpty-hot-path", targets: ["BenchLabptyHotPath"]),
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
      ],
      swiftSettings: _releaseExclusivity
    ),
    .target(
      name: "LabanCore",
      dependencies: ["LabanTerminalCore", "LabanRenderer"],
      swiftSettings: _releaseExclusivity
    ),
    .target(
      name: "LabanDebug",
      dependencies: ["LabanCore", "LabanControl", "LabanRenderer", "LabanTerminalCore"]
    ),
    .target(
      name: "LabanControl",
      dependencies: ["LabanCore"]
    ),
    .executableTarget(
      name: "LabanApp",
      dependencies: ["LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore", "LabanControl"],
      resources: [.copy("Resources/AppIcon.icns")],
      swiftSettings: _releaseExclusivity
    ),
    .executableTarget(
      name: "LabanAgent",
      dependencies: [
        "LabanCore", "LabanRenderer", "LabanDebug", "LabanTerminalCore", "LabanControl",
      ]
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
    .executableTarget(
      name: "LabptyDump",
      dependencies: ["LabanCore"],
      path: "Tools/LabptyDump"
    ),
    .executableTarget(
      name: "BenchLabptyHotPath",
      dependencies: ["LabanCore", "LabanTerminalCore"],
      path: "Tools/BenchLabptyHotPath"
    ),
    .testTarget(
      name: "LabanTerminalCoreTests",
      dependencies: ["LabanTerminalCore"]
    ),
    .testTarget(
      name: "LabanCoreTests",
      dependencies: ["LabanCore", "LabanTerminalCore", "LabanRenderer", "Labpty", "Laband"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "LabanRendererTests",
      dependencies: ["LabanRenderer"]
    ),
    .testTarget(
      name: "LabanDebugTests",
      dependencies: ["LabanDebug", "LabanControl", "Laband"],
      exclude: ["Fixtures"]
    ),
    .testTarget(
      name: "LabanControlTests",
      dependencies: ["LabanControl", "LabanCore"]
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
      dependencies: ["LabanApp", "LabanControl", "Laband", "Labpty"],
      exclude: ["Fixtures"]
    ),
  ]
)
