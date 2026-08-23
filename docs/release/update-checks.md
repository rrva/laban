# Updates (Sparkle)

Release builds of Laban update themselves with
[Sparkle 2](https://sparkle-project.org/): the app periodically checks an
appcast feed, downloads newer versions, verifies their EdDSA signature, and
offers to install and relaunch. Dev builds (anything stamped `0.0.0`, which
includes all `scripts/build-app` and `swift run` output) carry no feed URL and
never contact the update server; their "Check for Updates…" menu item says so
instead of checking.

## How it fits together

- **Feed**: `appcast.xml` at the repository root, served from
  `https://raw.githubusercontent.com/rrva/laban/main/appcast.xml`. Each entry's
  enclosure points at a zip attached to a GitHub Release on `rrva/laban` and
  carries a `sparkle:edSignature`.
- **App side**: `Sources/LabanApp/UpdaterController.swift` owns the
  `SPUStandardUpdaterController`; `SparkleUpdatePolicy.isConfigured` gates
  everything on the presence of `SUFeedURL` + `SUPublicEDKey` in Info.plist.
  `scripts/build-app` stamps those keys only when `LABAN_SPARKLE_FEED_URL` is
  set (done by `scripts/package-zip`).
- **Keys**: the Info.plist `SUPublicEDKey` (baked into `scripts/build-app`)
  is the public half of an Ed25519 keypair. The private half signs appcast
  entries and must never enter the repo. It currently lives in
  `.artifacts/sparkle/laban-ed25519-private-key` (mode 600, gitignored);
  import it into the login Keychain with
  `.artifacts/sparkle/bin/generate_keys -f <file>` if you prefer Keychain
  storage, and keep a backup (a Passwords-app entry works — the file contents
  are a short base64 string). If the key is ever lost, recovery is possible
  because releases are Developer ID signed: ship an update signed with a new
  EdDSA key under the same Developer ID certificate and Sparkle accepts the
  rotation (change one or the other per release, never both).
- **Notarization**: independent of Sparkle. Gatekeeper requires it for the
  downloaded zip to launch on other Macs, so `package-zip` notarizes when
  `LABAN_NOTARY_PROFILE` is set.

One-time setup:

```sh
# notarytool credentials (asks for Apple ID / app-specific password or
# App Store Connect API key options — see man notarytool):
xcrun notarytool store-credentials laban-notary
```

## Cutting a release

One command runs the whole pipeline (prompts for the login keychain
password, builds, signs, notarizes, pushes branch + tag, creates the GitHub
release, and commits + pushes the regenerated appcast):

```sh
./scripts/release <version>
```

The same steps spelled out, for when you want to run them individually:

```sh
# 1. Optional: write release notes; they feed both the GitHub release body
#    and the appcast entry.
$EDITOR .artifacts/release/Laban-<version>.md

# 2. Build, sign (Developer ID + hardened runtime), notarize, staple, zip.
LABAN_NOTARY_PROFILE=laban-notary ./scripts/package-zip <version>

# 3. Commit and push the code, and push/create the tag v<version>.
# 4. Create the GitHub release, upload the zip, regenerate appcast.xml.
./scripts/publish-release <version>

# 5. Review, commit, and push appcast.xml (the script does not touch git).
```

`package-zip` stamps `CFBundleVersion` with epoch seconds by default
(Sparkle compares build numbers, not marketing versions); override with
`LABAN_BUILD_NUMBER` if you ever need to.

## Verifying a release

- `plutil -extract SUFeedURL raw -o - .build/laban/Laban.app/Contents/Info.plist`
  prints the feed URL; `codesign --verify --deep --strict` on the bundle exits
  0; `xcrun stapler validate` passes after notarization.
- Definition of done: an installed *previous* release offers the new version
  via Laban menu → "Check for Updates…" and installs it.
- To test the flow without a release, point the feed override at a test
  appcast advertising a higher version. Sparkle fetches feeds with
  NSURLSession, so the URL must be HTTP(S) — `file://` feeds silently find
  nothing. A loopback server works (ATS allows loopback):

  ```sh
  (cd /path/to/feed-dir && python3 -m http.server 8899) &
  defaults write com.laban.LabanApp SUFeedURL 'http://127.0.0.1:8899/appcast.xml'
  # Background checks are throttled to once per 24h; reset the timer to
  # test immediately:
  defaults delete com.laban.LabanApp SULastCheckTime
  ```

  The update bundle's `CFBundleIdentifier` must match the running app's, and
  the install only completes once the app actually quits (a live terminal
  session ignores Sparkle's gentle termination request).

## Settings

Settings → Terminal → "Automatically check for updates" toggles Sparkle's
`automaticallyChecksForUpdates` (visible only in builds with a configured
feed). The manual "Check for Updates…" item in the Laban menu always works in
release builds.
