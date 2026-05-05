# Manual Update Checks

Laban's update check is intentionally manual. It reads a tiny JSON manifest,
compares the manifest's `latest` version to the running
`CFBundleShortVersionString`, and opens the manifest's zip URL in the user's web
browser when an update is available.

It does not download, install, replace, or execute anything.

## Manifest

```json
{
  "latest": "0.1.0",
  "link": "https://example.com/Laban-0.1.0.zip",
  "notes": "Optional short release note shown in the update alert."
}
```

`latest` is compared as dotted numeric version text. `link` must be the public
URL of the zip file the browser should open.

The checker also accepts `version` instead of `latest`, and `url`,
`downloadURL`, or `downloadUrl` instead of `link`.

## Google Drive

For a public Google Drive file, share the JSON file as "anyone with the link can
view" and configure Laban with the direct download form:

```text
https://drive.google.com/uc?export=download&id=<FILE_ID>
```

Keep the zip itself on a normal public URL when possible. Google Drive is
acceptable for the small manifest, but GitHub Releases is simpler and more
predictable for release zips.

## Build Configuration

Build an unsigned release zip with the app version and manifest URL:

```sh
./scripts/package-zip 0.1.0
```

It writes `.artifacts/release/Laban-0.1.0.zip`. Upload that zip and put its
public URL in the manifest's `link` field.

The package script stamps the public Laban manifest URL by default:

```text
https://drive.google.com/uc?export=download&id=1021htaI6ngLEoF1ItVLvFJHzP-TczOeG
```

The script uses macOS `ditto -c -k --sequesterRsrc --keepParent` so the app
bundle's macOS metadata is preserved in the zip.

For local testing without rebuilding the app bundle, set a user default:

```sh
defaults write com.laban.LabanApp LabanUpdateManifestURL \
  'https://drive.google.com/uc?export=download&id=<FILE_ID>'
```
