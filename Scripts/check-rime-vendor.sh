#!/usr/bin/env bash

set -euo pipefail

# Validate whether the local iOS librime vendor drop is ready for the
# SimpaninKeyboard app extension integration.
#
# Usage:
#   bash Scripts/check-rime-vendor.sh
#
# Accepted layouts:
#   Vendor/Rime/include/rime_api.h + Vendor/Rime/lib/librime.a
#   Vendor/Rime/Rime.xcframework

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIME_DIR="${ROOT_DIR}/Vendor/Rime"
HEADER_PATH="${RIME_DIR}/include/rime_api.h"
STATIC_LIB_PATH="${RIME_DIR}/lib/librime.a"
XCFRAMEWORK_PATH="${RIME_DIR}/Rime.xcframework"
RIME_SHARED_DIR="${ROOT_DIR}/SimpaninKeyboard/RimeShared"
RIME_SHARED_MANIFEST="${RIME_SHARED_DIR}/rime-shared-manifest.json"
REQUIRED_STATIC_LIBS=(
  "librime.a"
  "libboost_regex.a"
  "libglog.a"
  "libleveldb.a"
  "libmarisa.a"
  "libopencc.a"
  "libyaml-cpp.a"
)

status=0

info() {
  printf '==> %s\n' "$1"
}

warn() {
  printf 'warning: %s\n' "$1" >&2
}

fail() {
  printf 'error: %s\n' "$1" >&2
  status=1
}

info "Checking Rime vendor directory: ${RIME_DIR}"

if [[ ! -d "${RIME_DIR}" ]]; then
  fail "Vendor/Rime directory is missing."
  exit "${status}"
fi

if [[ -d "${XCFRAMEWORK_PATH}" ]]; then
  info "Found Rime.xcframework."

  if /usr/bin/find "${XCFRAMEWORK_PATH}" -type f -name 'rime_api.h' -print -quit | grep -q .; then
    info "Found rime_api.h inside Rime.xcframework."
  elif [[ -f "${HEADER_PATH}" ]]; then
    info "Found external header: Vendor/Rime/include/rime_api.h"
  else
    warn "No rime_api.h found in Rime.xcframework or Vendor/Rime/include. Confirm the framework exports the C API headers."
  fi

  if /usr/bin/find "${XCFRAMEWORK_PATH}" -type d -name '*ios-arm64*' -print -quit | grep -q .; then
    info "Rime.xcframework contains an iOS arm64 slice directory."
  else
    warn "Could not detect an ios-arm64 slice directory in Rime.xcframework. Verify the xcframework supports iphoneos arm64."
  fi

  info "Next: add Rime.xcframework to the SimpaninKeyboard target and keep APPLICATION_EXTENSION_API_ONLY=YES compatibility."
  exit "${status}"
fi

if [[ -f "${HEADER_PATH}" ]]; then
  info "Found header: Vendor/Rime/include/rime_api.h"
else
  fail "Missing header: Vendor/Rime/include/rime_api.h"
fi

if [[ -f "${STATIC_LIB_PATH}" ]]; then
  info "Found static library: Vendor/Rime/lib/librime.a"

  if command -v lipo >/dev/null 2>&1; then
    for lib_name in "${REQUIRED_STATIC_LIBS[@]}"; do
      lib_path="${RIME_DIR}/lib/${lib_name}"
      if [[ ! -f "${lib_path}" ]]; then
        fail "Missing static dependency: Vendor/Rime/lib/${lib_name}"
        continue
      fi

      archs="$(lipo -archs "${lib_path}" 2>/dev/null || true)"
      if [[ -n "${archs}" ]]; then
        info "${lib_name} architectures: ${archs}"
        if [[ " ${archs} " != *" arm64 "* ]]; then
          fail "${lib_name} does not contain arm64. iPhoneOS builds require arm64."
        fi
      else
        warn "Could not read ${lib_name} architectures with lipo. Verify the archive is a valid iOS static library."
      fi
    done
  else
    warn "lipo is unavailable; skipping architecture validation."
  fi

  if command -v nm >/dev/null 2>&1; then
    symbol_output="$(nm -gU "${STATIC_LIB_PATH}" 2>/dev/null || true)"
    if grep -Eq 'rime_require_module_(lua|octagram)|luaopen_' <<<"${symbol_output}"; then
      info "librime.a contains merged Lua/octagram plugin symbols."
    else
      fail "librime.a does not appear to contain merged Lua/octagram plugin symbols required by Wanxiang."
    fi
  else
    warn "nm is unavailable; skipping merged plugin symbol validation."
  fi
else
  fail "Missing static library: Vendor/Rime/lib/librime.a"
fi

if [[ -d "${RIME_SHARED_DIR}" ]]; then
  info "Found RimeShared resource directory."
  for required_resource in \
    "default.yaml" \
    "wanxiang.schema.yaml" \
    "wanxiang.dict.yaml" \
    "wanxiang-lts-zh-hans.gram" \
    "lua/wanxiang/wanxiang.lua" \
    "dicts/jichu.dict.yaml" \
    "dicts/lianxiang.dict.yaml"; do
    if [[ -f "${RIME_SHARED_DIR}/${required_resource}" ]]; then
      info "Found RimeShared/${required_resource}"
    else
      fail "Missing RimeShared/${required_resource}"
    fi
  done

  if [[ -f "${RIME_SHARED_MANIFEST}" ]]; then
    info "Found RimeShared manifest."
  else
    fail "Missing RimeShared/rime-shared-manifest.json"
  fi
else
  fail "Missing SimpaninKeyboard/RimeShared directory."
fi

if [[ "${status}" -eq 0 ]]; then
  info "Rime vendor files, merged plugins, and Wanxiang resources are present for the static-library layout."
else
  warn "Rime vendor files are incomplete. The current Swift fallback remains the safe runtime path."
fi

exit "${status}"
