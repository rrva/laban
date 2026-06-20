import Foundation
import LabanControl
import LabanCore

// LabanControlGen — deterministic generator + gate for the control surface.
//
//   swift run LabanControlGen --write   # regenerate the committed discovery doc
//   swift run LabanControlGen --check   # CI gate: regen+diff, schemas exist, catalog valid
//
// It walks the shared `ControlRouteCatalog` (the same metadata the live `/debug`
// discovery response serves) so the committed doc and the wire never drift, and
// validates that every route's declared legacy schema file exists and the
// `IntentCatalog` is well-formed (unique ids, fixture ops never gui-available,
// route-aware input/output schema presence).

let discoveryDocPath = "schemas/debug/discovery-endpoints.json"

/// Mirrors `LabanDebug.DebugDiscoveryEndpoint` field-for-field so the generated
/// doc is byte-identical to the live discovery `endpoints` array.
struct DiscoveryEndpoint: Encodable {
  var method: String
  var path: String
  var category: String
  var summary: String
  var queryParameters: [String]
  var requestSchema: String?
  var responseSchema: String?

  init(binding: HTTPBinding) {
    method = binding.method
    path = binding.path
    category = binding.category
    summary = binding.summary
    queryParameters = binding.queryParameters
    requestSchema = binding.legacyRequestSchemaPath
    responseSchema = binding.legacyResponseSchemaPath
  }
}

func renderDiscoveryDoc() throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
  let endpoints = ControlRouteCatalog.endpoints.map { DiscoveryEndpoint(binding: $0.binding) }
  return String(data: try encoder.encode(endpoints), encoding: .utf8)!
}

/// Route-aware schema + capability validation. Artifact/binary routes need no
/// JSON schema; pure reads need no input schema; grandfathered routes bind via
/// the catalog's legacy schema paths. Returns human-readable failures.
func validate(repoRoot: URL) -> [String] {
  var errors: [String] = []

  for endpoint in ControlRouteCatalog.endpoints {
    let binding = endpoint.binding
    for path in [binding.legacyRequestSchemaPath, binding.legacyResponseSchemaPath]
      .compactMap({ $0 })
    {
      let url = repoRoot.appendingPathComponent(path)
      if !FileManager.default.fileExists(atPath: url.path) {
        errors.append("\(binding.method) \(binding.path) references missing schema: \(path)")
      }
    }
  }

  do {
    try IntentCatalog.all.validate(endpointDescriptors: ControlRouteCatalog.endpoints)
  } catch {
    errors.append("IntentCatalog.validate failed: \(error)")
  }

  return errors
}

let arguments = CommandLine.arguments
let mode = arguments.dropFirst().first ?? "--check"
let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let docURL = repoRoot.appendingPathComponent(discoveryDocPath)

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("LabanControlGen: \(message)\n".utf8))
  exit(1)
}

let generated: String
do {
  generated = try renderDiscoveryDoc()
} catch {
  fail("failed to render discovery doc: \(error)")
}

switch mode {
case "--write":
  do {
    try generated.write(to: docURL, atomically: true, encoding: .utf8)
    print("LabanControlGen: wrote \(discoveryDocPath)")
  } catch {
    fail("failed to write \(discoveryDocPath): \(error)")
  }

case "--check":
  var errors = validate(repoRoot: repoRoot)
  let committed = (try? String(contentsOf: docURL, encoding: .utf8))
  if committed == nil {
    errors.append("missing committed discovery doc: \(discoveryDocPath) (run --write)")
  } else if committed != generated {
    errors.append(
      "discovery doc out of date: \(discoveryDocPath) differs from the catalog (run --write)")
  }
  if errors.isEmpty {
    print("LabanControlGen: check passed")
  } else {
    for error in errors { FileHandle.standardError.write(Data("LabanControlGen: \(error)\n".utf8)) }
    exit(1)
  }

default:
  fail("unknown mode '\(mode)' (use --write or --check)")
}
