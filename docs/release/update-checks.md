# Manual Update Checks

Laban's update check is intentionally manual. It reads a tiny JSON manifest,
compares the manifest's `latest` version to the running
`CFBundleShortVersionString`, and opens the manifest's zip URL in the user's web
browser when an update is available.

It does not download, install, replace, or execute anything.

## Background Auto-Check Badge

Stamped release builds (i.e. `CFBundleShortVersionString != 0.0.0`) hit the
manifest on every launch, and — for an already-running process — after wake /
activation and every 4 hours. The 4-hour cooldown throttles only the
running-app triggers; a fresh launch always checks, so quitting and reopening
surfaces a new release without waiting out the cooldown. The check is silent on
failure; when a newer version is reported, a subtle pill in the bottom-left of
the main window shows `↓ <version>`. Clicking it routes through the same alert
as the menu's "Check for Updates" action. `swift run` builds are unstamped and
skip the auto-check entirely.

Policy decisions live in `UpdateAutoCheck.decide(...)` and are covered by
`UpdateAutoCheckTests`. The last-check timestamp persists in the
`LabanUpdateLastCheck` user default.

## Release Fast Path

1. Build the release zip:

   ```sh
   ./scripts/package-zip 0.4.0
   ```

   For a normal release, it is OK to just increment the version number in this
   command. The zip is written to `.artifacts/release/Laban-<version>.zip`.

2. Upload the zip as a new file in the Laban Drive release folder:

   ```text
   https://drive.google.com/drive/folders/0AOJsI5dKCixPUk9PVA
   ```

   Do not upload a new version/revision of an existing zip. The zip file URL
   should change for every release upload so clients cannot receive a cached
   copy. After upload, share the zip as "anyone with the link can view" and use
   its new file ID in the manifest `link` field.

3. Update the existing manifest file as a new Drive version/revision:

   ```text
   https://drive.google.com/file/d/1021htaI6ngLEoF1ItVLvFJHzP-TczOeG/view
   ```

   Do not delete and recreate `laban-latest.json`. The app is stamped with this
   manifest file ID, so the manifest URL must stay stable.

4. Verify the public manifest URL still returns the new JSON:

   ```sh
   curl -L --fail \
     'https://drive.google.com/uc?export=download&id=1021htaI6ngLEoF1ItVLvFJHzP-TczOeG'
   ```

5. Verify the manifest `link` downloads the same bytes as the local zip:

   ```sh
   shasum -a 256 .artifacts/release/Laban-<version>.zip
   curl -L --fail -o /tmp/Laban-<version>.zip '<manifest link>'
   shasum -a 256 /tmp/Laban-<version>.zip
   ```

## Drive CLI Fast Path

For agent-driven releases, check for the local `gws` CLI before trying browser
automation or generic Drive connector discovery:

```sh
which gws
gws --help
```

`gws` can upload raw zip bytes and update the existing manifest revision without
opening Chrome:

```sh
version=0.4.3
folder_id=0AOJsI5dKCixPUk9PVA
manifest_id=1021htaI6ngLEoF1ItVLvFJHzP-TczOeG
zip=".artifacts/release/Laban-${version}.zip"
manifest=".artifacts/release/laban-latest-${version}.json"

gws drive files create \
  --params '{"supportsAllDrives":true,"fields":"id,name,mimeType,size,md5Checksum,sha256Checksum,webContentLink,webViewLink"}' \
  --json "{\"name\":\"Laban-${version}.zip\",\"mimeType\":\"application/zip\",\"parents\":[\"${folder_id}\"]}" \
  --upload "$zip" \
  --upload-content-type application/zip

gws drive permissions create \
  --params '{"fileId":"<ZIP_FILE_ID>","supportsAllDrives":true,"sendNotificationEmail":false,"fields":"id,type,role"}' \
  --json '{"type":"anyone","role":"reader"}'

cat > "$manifest" <<EOF
{
  "latest": "${version}",
  "link": "https://drive.google.com/uc?export=download&id=<ZIP_FILE_ID>",
  "notes": "Laban ${version} release."
}
EOF

gws drive files update \
  --params "{\"fileId\":\"${manifest_id}\",\"supportsAllDrives\":true,\"fields\":\"id,name,mimeType,size,md5Checksum,modifiedTime,webContentLink,webViewLink\"}" \
  --json '{"name":"laban-latest.json","mimeType":"application/json"}' \
  --upload "$manifest" \
  --upload-content-type application/json
```

Keep using a new Drive file ID for each zip. Keep updating
`laban-latest.json` in place so the manifest ID stamped into the app remains
stable.

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

Keep the manifest file ID stable by uploading a new version/revision of
`laban-latest.json` instead of creating a replacement file. The zip should use a
new file ID on every release upload to avoid cached downloads. Google Drive is
acceptable for the small manifest, but GitHub Releases is simpler and more
predictable for release zips.

## Build Configuration

Build a release zip with the app version and manifest URL:

```sh
./scripts/package-zip 0.1.0
```

It writes `.artifacts/release/Laban-0.1.0.zip`. Release zips are signed with
the distribution identity by default (`Developer ID Application: Ragnar Rova
(3563RJWBQP)`, persisted as the default in `scripts/package-zip`) so downloaded
zips carry a valid Developer ID signature. Set `LABAN_CODESIGN_IDENTITY=-` for
an ad-hoc signed build, or any other identity to override. Upload that zip and
put its public URL in the manifest's `link` field.

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
