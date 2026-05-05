import Foundation

struct UpdateManifest: Equatable {
  let latest: String
  let downloadURL: URL
  let notes: String?
}

extension UpdateManifest: Decodable {
  enum CodingKeys: String, CodingKey {
    case latest
    case version
    case link
    case url
    case downloadURL
    case downloadUrl
    case notes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let latest =
        try container.decodeIfPresent(String.self, forKey: .latest)
        ?? container.decodeIfPresent(String.self, forKey: .version)
    else {
      throw DecodingError.keyNotFound(
        CodingKeys.latest,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Update manifest needs latest or version"))
    }

    guard
      let downloadURL =
        try container.decodeIfPresent(URL.self, forKey: .link)
        ?? container.decodeIfPresent(URL.self, forKey: .url)
        ?? container.decodeIfPresent(URL.self, forKey: .downloadURL)
        ?? container.decodeIfPresent(URL.self, forKey: .downloadUrl)
    else {
      throw DecodingError.keyNotFound(
        CodingKeys.link,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Update manifest needs link, url, downloadURL, or downloadUrl"))
    }
    guard let scheme = downloadURL.scheme?.lowercased(), scheme == "https" || scheme == "http"
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .link,
        in: container,
        debugDescription: "Update download URL must use http or https")
    }

    self.latest = latest
    self.downloadURL = downloadURL
    self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
  }
}

enum UpdateCheckResult: Equatable {
  case available(UpdateManifest)
  case upToDate(UpdateManifest)
}

enum UpdateCheckError: Error, LocalizedError {
  case emptyResponse
  case nonHTTPResponse
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .emptyResponse:
      return "The update manifest was empty."
    case .nonHTTPResponse:
      return "The update server returned an invalid response."
    case .httpStatus(let status):
      return "The update server returned HTTP \(status)."
    }
  }
}

enum UpdateChecker {
  static let manifestURLBundleKey = "LABANUpdateManifestURL"
  static let manifestURLDefaultsKey = "LabanUpdateManifestURL"

  static func configuredManifestURL(
    bundle: Bundle = .main,
    defaults: UserDefaults = .standard
  ) -> URL? {
    let defaultsURL = defaults.string(forKey: manifestURLDefaultsKey)
    let bundleURL = bundle.object(forInfoDictionaryKey: manifestURLBundleKey) as? String
    return [defaultsURL, bundleURL]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
      .flatMap(validManifestURL)
  }

  static func check(
    manifestURL: URL,
    currentVersion: String,
    completion: @escaping (Result<UpdateCheckResult, Error>) -> Void
  ) {
    var request = URLRequest(url: manifestURL)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        completion(.failure(error))
        return
      }
      guard let response = response as? HTTPURLResponse else {
        completion(.failure(UpdateCheckError.nonHTTPResponse))
        return
      }
      guard (200..<300).contains(response.statusCode) else {
        completion(.failure(UpdateCheckError.httpStatus(response.statusCode)))
        return
      }
      guard let data, !data.isEmpty else {
        completion(.failure(UpdateCheckError.emptyResponse))
        return
      }

      completion(Result { try evaluate(data: data, currentVersion: currentVersion) })
    }.resume()
  }

  static func evaluate(data: Data, currentVersion: String) throws -> UpdateCheckResult {
    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
    if isNewer(manifest.latest, than: currentVersion) {
      return .available(manifest)
    }
    return .upToDate(manifest)
  }

  static func isNewer(_ candidate: String, than current: String) -> Bool {
    compareVersions(candidate, current) == .orderedDescending
  }

  static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = versionComponents(lhs)
    let right = versionComponents(rhs)
    let count = max(left.count, right.count)

    for index in 0..<count {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l < r { return .orderedAscending }
      if l > r { return .orderedDescending }
    }
    return .orderedSame
  }

  private static func validManifestURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else {
      return nil
    }
    return url
  }

  private static func versionComponents(_ value: String) -> [Int] {
    value
      .split(separator: ".", omittingEmptySubsequences: false)
      .map { component in
        let digits = component.prefix { $0.isNumber }
        return Int(digits) ?? 0
      }
  }
}
