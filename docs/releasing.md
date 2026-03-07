# Releasing Port Menu

This document covers the maintainer workflow for shipping a signed, notarized direct-download DMG.

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

If the notarization keychain profile is unavailable in CI or a fresh shell session, you can pass credentials directly instead:

```bash
TEAM_ID="YOUR_TEAM_ID" \
DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
NOTARY_APPLE_ID="you@example.com" \
NOTARY_PASSWORD="app-specific-password" \
./scripts/release-macos.sh
```

Optional environment variables:

- `SCHEME` defaults to `Porter`
- `PROJECT` defaults to `Porter.xcodeproj`
- `APP_NAME` defaults to `Port Menu`
- `NOTARY_PROFILE` defaults to `AC_PASSWORD`
- `NOTARY_APPLE_ID` optionally overrides keychain-profile auth
- `NOTARY_PASSWORD` optionally overrides keychain-profile auth
- `OUTPUT_DIR` defaults to `dist`

The script produces:

- a signed `.app`
- a notarized `.dmg` with an `Applications` alias for drag-and-drop install
- a stapled app bundle and stapled DMG ready for distribution

## Verify the release

```bash
spctl --assess --type execute --verbose=4 "dist/Port Menu.app"
xcrun stapler validate "dist/Port Menu.app"
codesign --verify --deep --strict --verbose=2 "dist/Port Menu.app"
spctl --assess --type open --context context:primary-signature --verbose=4 "dist/Port Menu.dmg"
xcrun stapler validate "dist/Port Menu.dmg"
codesign --verify --verbose=2 "dist/Port Menu.dmg"
shasum -a 256 "dist/Port Menu.dmg"
```

## Publish to GitHub Releases

Create a versioned asset name and publish it:

```bash
cp "dist/Port Menu.dmg" "dist/PortMenu-<version>.dmg"
gh release create "v<version>" "dist/PortMenu-<version>.dmg#PortMenu-<version>.dmg"
```

Or upload the asset to an existing draft release:

```bash
gh release upload "v<version>" "dist/PortMenu-<version>.dmg#PortMenu-<version>.dmg"
```
