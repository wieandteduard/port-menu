#!/bin/zsh

set -euo pipefail

PROJECT="${PROJECT:-Porter.xcodeproj}"
SCHEME="${SCHEME:-Porter}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-Port Menu}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
ARCHIVE_PATH="${OUTPUT_DIR}/${APP_NAME}.xcarchive"
EXPORT_APP_PATH="${OUTPUT_DIR}/${APP_NAME}.app"
STAGING_DIR="${OUTPUT_DIR}/dmg-staging"
ZIP_PATH="${OUTPUT_DIR}/${APP_NAME}.zip"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID.}"
: "${DEVELOPER_ID_APP:?Set DEVELOPER_ID_APP to your Developer ID Application signing identity.}"

rm -rf "${ARCHIVE_PATH}" "${EXPORT_APP_PATH}" "${STAGING_DIR}" "${ZIP_PATH}" "${DMG_PATH}"
mkdir -p "${OUTPUT_DIR}"

echo "Archiving ${APP_NAME}..."
xcodebuild archive \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -archivePath "${ARCHIVE_PATH}" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_IDENTITY="${DEVELOPER_ID_APP}"

cp -R "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app" "${EXPORT_APP_PATH}"

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${EXPORT_APP_PATH}"

echo "Creating notarization archive..."
/usr/bin/ditto -c -k --keepParent "${EXPORT_APP_PATH}" "${ZIP_PATH}"

submit_for_notarization() {
  local artifact_path="$1"
  if [[ -n "${NOTARY_APPLE_ID}" && -n "${NOTARY_PASSWORD}" ]]; then
    xcrun notarytool submit "${artifact_path}" \
      --apple-id "${NOTARY_APPLE_ID}" \
      --team-id "${TEAM_ID}" \
      --password "${NOTARY_PASSWORD}" \
      --wait
  else
    xcrun notarytool submit "${artifact_path}" \
      --keychain-profile "${NOTARY_PROFILE}" \
      --wait
  fi
}

echo "Submitting app for notarization..."
submit_for_notarization "${ZIP_PATH}"

echo "Stapling app notarization ticket..."
xcrun stapler staple "${EXPORT_APP_PATH}"

echo "Preparing DMG staging folder..."
mkdir -p "${STAGING_DIR}"
cp -R "${EXPORT_APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "Creating DMG..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "Signing DMG..."
codesign --force --sign "${DEVELOPER_ID_APP}" "${DMG_PATH}"

echo "Submitting DMG for notarization..."
submit_for_notarization "${DMG_PATH}"

echo "Stapling DMG notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo "Release ready:"
echo "  App: ${EXPORT_APP_PATH}"
echo "  DMG: ${DMG_PATH}"
