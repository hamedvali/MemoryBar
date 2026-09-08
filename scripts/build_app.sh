#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${1:-${ROOT_DIR}/outputs/MemoryBar.app}"
BUILD_DIR="${ROOT_DIR}/.build"

mkdir -p "${ROOT_DIR}/outputs"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

CLANG_MODULE_CACHE_PATH="/private/tmp/memorybar-clang-cache" \
SWIFT_MODULECACHE_PATH="/private/tmp/memorybar-swift-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/memorybar-manifest-cache" \
swift build -c release --scratch-path "${BUILD_DIR}"

cp "${BUILD_DIR}/release/MemoryBar" "${APP_DIR}/Contents/MacOS/MemoryBar"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
xcrun actool "${ROOT_DIR}/Resources/Assets.xcassets" \
    --compile "${APP_DIR}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "${BUILD_DIR}/AssetInfo.plist"
xattr -cr "${APP_DIR}"
# A default ad-hoc signature uses the changing CDHash as its designated
# requirement, which makes macOS privacy grants look like they belong to a
# different app after every rebuild. This explicit local requirement keeps the
# MVP's identity stable until it is replaced by a Developer ID signature.
codesign --force --deep --sign - \
    -r '=designated => identifier "com.localfirst.memorybar"' \
    "${APP_DIR}"
xattr -cr "${APP_DIR}"

echo "Built ${APP_DIR}"
