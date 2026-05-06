# Manual Update Checks

Laban's update check is intentionally manual. It reads a tiny JSON manifest,
compares the manifest's `latest` version to the running
`CFBundleShortVersionString`, and opens the manifest's zip URL in the user's web
browser when an update is available.

It does not download, install, replace, or execute anything.

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
