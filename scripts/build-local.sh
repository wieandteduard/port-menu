#!/bin/zsh

# Build a locally runnable Port Menu from this fork.
#
# Why this script exists: the project is configured for the upstream maintainer's
# Team ID (LU4CMSAS7X), whose "Mac Development" certificate no local machine has.
# `xcodebuild` therefore fails with "No signing certificate". There is also no
# Sparkle feed worth checking on a fork, so local builds skip the updater
# (see `UpdaterPolicy` in Porter/PorterApp.swift).
#
# Signing is ad-hoc (`CODE_SIGN_IDENTITY="-"`): enough for the app to launch on
# Apple Silicon and to keep the bundle sealed with its entitlements, but not
# enough for `SMAppService` launch-at-login, which needs a real certificate.
#
# Usage:
#   ./scripts/build-local.sh            # Debug build
#   CONFIGURATION=Release ./scripts/build-local.sh
#   ./scripts/build-local.sh --run      # build, then launch the product

set -euo pipefail

PROJECT="${PROJECT:-Porter.xcodeproj}"
SCHEME="${SCHEME:-Porter}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
APP_NAME="${APP_NAME:-Port Menu}"

# Intermediate xcodebuild noise (CoreSimulator warnings, destination chatter).
FILTER='CoreSimulator|DVTErrorPresenter|^Domain:|Failure Reason|Recovery Suggestion|^Code: |^--$|iOSSimulator|Simulator device support|matching destinations|^\s*\{ platform:macOS'

run=false
for arg in "$@"; do
    case "$arg" in
        --run) run=true ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

echo "==> Building ${APP_NAME} (${CONFIGURATION})"
xcodebuild build \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_ENTITLEMENTS="Porter/Porter.entitlements" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    2>&1 | grep -viE "${FILTER}" || true

BUILD_DIR="$(xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "build did not produce ${APP_PATH}" >&2
    exit 1
fi

echo "==> Signed as:"
codesign -dv "${APP_PATH}" 2>&1 | sed -n '1,4p' | sed 's/^/    /'

echo "==> Product: ${APP_PATH}"

if [[ "${run}" == true ]]; then
    echo "==> Launching"
    open "${APP_PATH}"
fi
