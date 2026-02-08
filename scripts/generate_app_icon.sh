#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR="${ROOT_DIR}/assets"
APPICONSET_DIR="${ROOT_DIR}/Resources/Assets.xcassets/AppIcon.appiconset"
BASE_PNG="${ASSETS_DIR}/AppIcon-1024.png"

mkdir -p "${ASSETS_DIR}"
mkdir -p "${APPICONSET_DIR}"

swift "${ROOT_DIR}/scripts/render_app_icon.swift" "${BASE_PNG}"

sips -z 16 16 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${BASE_PNG}" --out "${APPICONSET_DIR}/icon_512x512.png" >/dev/null
cp "${BASE_PNG}" "${APPICONSET_DIR}/icon_512x512@2x.png"

echo "Updated Xcode app icon set:"
echo "${APPICONSET_DIR}"
