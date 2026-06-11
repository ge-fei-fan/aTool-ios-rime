#!/usr/bin/env bash

set -euo pipefail

# Build an unsigned iPhoneOS .app and package it as an .ipa for TrollStore.
#
# Usage:
#   bash Scripts/build-trollstore-ipa.sh
#
# Optional environment variables:
#   PROJECT="Simpanin.xcodeproj"
#   SCHEME="Simpanin"
#   CONFIGURATION="Release"
#   APP_NAME="Simpanin"
#   OUTPUT_NAME="Simpanin-TrollStore.ipa"
#   INCLUDE_GRAMMAR="0" # Set to 1 to download and bundle wanxiang-lts-zh-hans.gram
#   GRAMMAR_NAME="wanxiang-lts-zh-hans.gram"
#   GRAMMAR_ASSET_SHA256="..." # Optional sha256 validation when INCLUDE_GRAMMAR=1

PROJECT="${PROJECT:-Simpanin.xcodeproj}"
SCHEME="${SCHEME:-Simpanin}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-Simpanin}"
OUTPUT_NAME="${OUTPUT_NAME:-${APP_NAME}-TrollStore.ipa}"
INCLUDE_GRAMMAR="${INCLUDE_GRAMMAR:-0}"
GRAMMAR_NAME="${GRAMMAR_NAME:-wanxiang-lts-zh-hans.gram}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/trollstore"
DERIVED_DATA_PATH="${BUILD_DIR}/DerivedData"
PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-iphoneos"
APP_PATH="${PRODUCTS_DIR}/${APP_NAME}.app"
PAYLOAD_DIR="${BUILD_DIR}/Payload"
IPA_PATH="${ROOT_DIR}/${OUTPUT_NAME}"
MAIN_ENTITLEMENTS="${ROOT_DIR}/Simpanin/Simpanin.entitlements"
KEYBOARD_ENTITLEMENTS="${ROOT_DIR}/SimpaninKeyboard/SimpaninKeyboard.entitlements"

echo "==> Project: ${PROJECT}"
echo "==> Scheme: ${SCHEME}"
echo "==> Configuration: ${CONFIGURATION}"
echo "==> Output: ${IPA_PATH}"
echo "==> Include Grammar: ${INCLUDE_GRAMMAR}"
echo "==> Grammar Name: ${GRAMMAR_NAME}"

cd "${ROOT_DIR}"

echo "==> Cleaning old build artifacts..."
rm -rf "${BUILD_DIR}" "${IPA_PATH}"
mkdir -p "${BUILD_DIR}"

if [[ "${INCLUDE_GRAMMAR}" == "1" ]]; then
  echo "==> Syncing bundled Rime data with Grammar..."
  bash "${ROOT_DIR}/Scripts/sync-rime-wanxiang.sh"
fi

echo "==> Prebuilding bundled Rime data..."
if [[ "${INCLUDE_GRAMMAR}" == "1" ]]; then
  REQUIRE_GRAMMAR=1 bash "${ROOT_DIR}/Scripts/prebuild-rime-shared.sh"
else
  bash "${ROOT_DIR}/Scripts/prebuild-rime-shared.sh"
fi

echo "==> Building unsigned iPhoneOS app..."
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -sdk iphoneos \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app not found: ${APP_PATH}" >&2
  echo "Try checking APP_NAME, SCHEME, or build output above." >&2
  exit 1
fi

if [[ "${INCLUDE_GRAMMAR}" != "1" ]]; then
  echo "==> Removing Grammar model from built app..."
  while IFS= read -r -d '' grammar_file; do
    echo "    remove ${grammar_file}"
    rm -f "${grammar_file}"
  done < <(find "${APP_PATH}" -type f -name "${GRAMMAR_NAME}" -print0)

  while IFS= read -r -d '' manifest_file; do
    echo "    update ${manifest_file}"
    python3 - "${manifest_file}" "${GRAMMAR_NAME}" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
grammar_name = sys.argv[2]
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

manifest["files"] = [
    entry for entry in manifest.get("files", [])
    if Path(entry.get("path", "")).name != grammar_name
]
manifest["grammarAssetName"] = None
manifest["grammarAssetSHA256"] = None

manifest_path.write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  done < <(find "${APP_PATH}" -type f -name "rime-shared-manifest.json" -print0)
fi

sign_binary_with_ldid() {
  local binary_path="$1"
  local entitlements_path="${2:-}"

  if [[ -f "${binary_path}" ]]; then
    if [[ -n "${entitlements_path}" ]]; then
      if [[ ! -f "${entitlements_path}" ]]; then
        echo "error: entitlements file not found: ${entitlements_path}" >&2
        exit 1
      fi

      echo "    ldid -S${entitlements_path} ${binary_path}"
      ldid -S"${entitlements_path}" "${binary_path}"
    else
      echo "    ldid -S ${binary_path}"
      ldid -S "${binary_path}"
    fi
  else
    echo "    skip missing binary: ${binary_path}"
  fi
}

echo "==> Removing stale code signatures and provisioning profiles..."
find "${APP_PATH}" -type d -name "_CodeSignature" -prune -exec rm -rf {} +
find "${APP_PATH}" -type f -name "embedded.mobileprovision" -delete

echo "==> Applying ldid pseudo-signing..."
if ! command -v ldid >/dev/null 2>&1; then
  echo "error: ldid is required to build a TrollStore IPA." >&2
  echo "Install it with: brew install ldid" >&2
  exit 1
fi

MAIN_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APP_PATH}/Info.plist")"
sign_binary_with_ldid "${APP_PATH}/${MAIN_EXECUTABLE}" "${MAIN_ENTITLEMENTS}"

if [[ -d "${APP_PATH}/Frameworks" ]]; then
  while IFS= read -r -d '' framework; do
    framework_name="$(basename "${framework}" .framework)"
    sign_binary_with_ldid "${framework}/${framework_name}"
  done < <(find "${APP_PATH}/Frameworks" -type d -name "*.framework" -print0)
fi

if [[ -d "${APP_PATH}/PlugIns" ]]; then
  while IFS= read -r -d '' appex; do
    appex_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${appex}/Info.plist")"
    appex_entitlements=""

    if [[ "$(basename "${appex}")" == "SimpaninKeyboard.appex" ]]; then
      appex_entitlements="${KEYBOARD_ENTITLEMENTS}"
    fi

    sign_binary_with_ldid "${appex}/${appex_executable}" "${appex_entitlements}"

    if [[ -d "${appex}/Frameworks" ]]; then
      while IFS= read -r -d '' framework; do
        framework_name="$(basename "${framework}" .framework)"
        sign_binary_with_ldid "${framework}/${framework_name}"
      done < <(find "${appex}/Frameworks" -type d -name "*.framework" -print0)
    fi
  done < <(find "${APP_PATH}/PlugIns" -type d -name "*.appex" -print0)
fi

echo "==> Packaging IPA..."
rm -rf "${PAYLOAD_DIR}"
mkdir -p "${PAYLOAD_DIR}"
cp -R "${APP_PATH}" "${PAYLOAD_DIR}/"

(
  cd "${BUILD_DIR}"
  /usr/bin/zip -qry "${IPA_PATH}" Payload
)

echo "==> Done."
echo "IPA exported at: ${IPA_PATH}"
