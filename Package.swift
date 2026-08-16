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

// Whole-module optimization (WMO) recompiles an entire module from scratch on
// any single-file edit; on LabanApp (the largest target) that dominated local
// `scripts/build-app --profile` turnaround (a one-line edit cost ~39s under
// WMO versus ~24s per-file, measured under the Swift Build system). Per-file
// compilation stays release/-O (unlike -Onone debug builds), so an edit only
// recompiles what changed, and is the default for that reason. It can make
// different cross-file inlining decisions than WMO, so LABAN_WMO_PROFILE=1
// opts back into WMO for a `--profile` build whose code shape must match a
// distributed release build exactly.
//
// -enable-batch-mode used to ride along here and cut the loop further, but
// the Swift Build system plans a release target as one WMO "Compilation
// Requirements" task that expects a single <module>-primary.d; batch mode
// makes the driver emit per-file dependency files instead, and the build
// dies on `unable to open dependencies file`. Per-file compilation alone
// keeps most of the win and plans correctly.
let _fastProfile: [SwiftSetting] =
  ProcessInfo.processInfo.environment["LABAN_WMO_PROFILE"] == "1"
  ? []
  : [
    .unsafeFlags(
      ["-no-whole-module-optimization"],
      .when(configuration: .release)
    )
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
    .executable(name: "laban", targets: ["LabanCLI"]),
    .executable(name: "find-perf", targets: ["FindPerf"]),
    .executable(name: "bench-pty-drain", targets: ["BenchPtyDrain"]),
    .executable(name: "bench-keystroke-latency", targets: ["BenchKeystrokeLatency"]),
    .executable(
      name: "transparency-renderer-bench",
      targets: ["TransparencyRendererBench"]),
    .executable(name: "labpty-dump", targets: ["LabptyDump"]),
    .executable(name: "bench-labpty-hot-path", targets: ["BenchLabptyHotPath"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-profile-recorder.git",
      .upToNextMinor(from: "0.3.18")
    ),
    .package(
      url: "https://github.com/sparkle-project/Sparkle",
      .upToNextMinor(from: "2.9.3")
    ),
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
        // .copy, not .process: the renderer compiles these from source at
        // startup via makeLibrary(source:), so the .metal text itself has to
        // reach the bundle. The Swift Build system honours .process by
        // compiling Metal into default.metallib and dropping the source,
        // which leaves every makeLibrary(source:) call with nothing to read.
        .copy("Shaders.metal"),
        .copy("VectorGlyphShaders.metal"),
        .copy("TranslucentSurfaceShaders.metal"),
      ],
      swiftSettings: _releaseExclusivity + _fastProfile
    ),
    .target(
      name: "LabanCore",
      dependencies: ["LabanTerminalCore", "LabanRenderer"],
      swiftSettings: _releaseExclusivity + _fastProfile
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
      name: "LabanControlGen",
      dependencies: ["LabanControl", "LabanCore"]
    ),
    .executableTarget(
      name: "LabanCLI",
      dependencies: ["LabanControl", "LabanCore"]
    ),
    .executableTarget(
      name: "LabanApp",
      dependencies: [
        "LabanCore", "LabanRenderer", "LabanTerminalCore", "LabanControl",
        .product(name: "ProfileRecorder", package: "swift-profile-recorder"),
        .product(name: "_ProfileRecorderSampleConversion", package: "swift-profile-recorder"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      resources: [
        .copy("Resources/AppIcon.icns"),
        .process("Resources/Localizable.xcstrings"),
        .copy("Resources/ThemeExamples"),
      ],
      swiftSettings: _releaseExclusivity + _fastProfile
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
      name: "TransparencyRendererBench",
      dependencies: ["LabanCore", "LabanRenderer", "LabanTerminalCore"],
      path: "Tools/TransparencyRendererBench",
      swiftSettings: _releaseExclusivity + _fastProfile
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
      dependencies: ["LabanDebug", "LabanControl", "Laband"]
    ),
    .testTarget(
      name: "LabanControlTests",
      dependencies: ["LabanControl", "LabanCore"]
    ),
    .testTarget(
      name: "LabanCLITests",
      dependencies: ["LabanCLI", "LabanControl"]
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
      dependencies: ["LabanApp", "LabanControl", "LabanDebug", "LabanAgent", "Laband", "Labpty"],
      exclude: ["Fixtures"],
      linkerSettings: [
        // LabanApp links Sparkle.framework; SwiftPM emits the framework next
        // to the test bundle (in the products directory), so extend the test
        // bundle's rpath to find it at load time.
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
      ]
    ),
    .testTarget(
      name: "LabanAgentTests",
      dependencies: ["LabanAgent", "LabanControl", "LabanCore"]
    ),
  ]
)
