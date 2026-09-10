#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${1:-${ROOT_DIR}/outputs/Payvand.app}"
BUILD_DIR="${PAYVAND_BUILD_DIR:-${ROOT_DIR}/.build}"

mkdir -p "${ROOT_DIR}/outputs"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

CLANG_MODULE_CACHE_PATH="/private/tmp/payvand-clang-cache" \
SWIFT_MODULECACHE_PATH="/private/tmp/payvand-swift-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/payvand-manifest-cache" \
swift build -c release --scratch-path "${BUILD_DIR}"

cp "${BUILD_DIR}/release/Payvand" "${APP_DIR}/Contents/MacOS/Payvand"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
xcrun actool "${ROOT_DIR}/Resources/Assets.xcassets" \
    --compile "${APP_DIR}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "${BUILD_DIR}/AssetInfo.plist"
clear_bundle_metadata() {
    xattr -cr "${APP_DIR}"
    # File Provider may immediately restore these directory attributes after
    # a recursive clear; codesign treats them as invalid bundle detritus.
    xattr -d com.apple.FinderInfo "${APP_DIR}" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "${APP_DIR}" 2>/dev/null || true
}

clear_bundle_metadata
# A default ad-hoc signature uses the changing CDHash as its designated
# requirement, which makes macOS privacy grants look like they belong to a
# different app after every rebuild. This explicit local requirement keeps the
# MVP's identity stable until it is replaced by a Developer ID signature.
codesign --force --deep --sign - \
    -r '=designated => identifier "com.localfirst.payvand"' \
    "${APP_DIR}"
clear_bundle_metadata

echo "Built ${APP_DIR}"
