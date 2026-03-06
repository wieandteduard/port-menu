# Releasing Port Menu

This document covers the maintainer workflow for shipping a signed, notarized direct-download build.

## Requirements

- `Developer ID Application` certificate installed in your login keychain
- Xcode command line tools with `xcodebuild`, `codesign`, and `xcrun`
- an Apple notarization profile stored in the keychain

Store notarization credentials once with:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

## Build, sign, notarize, staple

Run:

```bash
TEAM_ID="YOUR_TEAM_ID" \
DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
./scripts/release-macos.sh
```

Optional environment variables:

- `SCHEME` defaults to `Porter`
- `PROJECT` defaults to `Porter.xcodeproj`
- `APP_NAME` defaults to `Port Menu`
- `NOTARY_PROFILE` defaults to `AC_PASSWORD`
- `OUTPUT_DIR` defaults to `dist`

The script produces:

- a signed `.app`
- a notarized `.zip`
- a stapled app bundle ready for distribution

## Verify the release

```bash
spctl --assess --type execute --verbose=4 "dist/Port Menu.app"
xcrun stapler validate "dist/Port Menu.app"
codesign --verify --deep --strict --verbose=2 "dist/Port Menu.app"
shasum -a 256 "dist/Port Menu.zip"
```

## Publish to GitHub Releases

Create a versioned asset name and publish it:

```bash
cp "dist/Port Menu.zip" "dist/PortMenu-<version>.zip"
gh release create "v<version>" "dist/PortMenu-<version>.zip#PortMenu-<version>.zip"
```

Or upload the asset to an existing draft release:

```bash
gh release upload "v<version>" "dist/PortMenu-<version>.zip#PortMenu-<version>.zip"
```
