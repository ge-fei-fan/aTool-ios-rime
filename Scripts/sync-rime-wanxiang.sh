#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/build/wanxiang"
DEST_DIR="${ROOT_DIR}/SimpaninKeyboard/RimeShared"

WANXIANG_TAG="${WANXIANG_TAG:-v15.12.3}"
WANXIANG_COMMIT="${WANXIANG_COMMIT:-620fdfd25814d391ffb67f0707e13edd5f3894c6}"
BASE_ASSET_NAME="rime-wanxiang-base.zip"
BASE_ASSET_SHA256="0ef60ac1680a0d05184433f2b98270ea6872bec9a88e507d11d1146334e9df40"
GRAMMAR_ASSET_NAME="wanxiang-lts-zh-hans.gram"
GRAMMAR_ASSET_SHA256="${GRAMMAR_ASSET_SHA256:-}"

BASE_URL="https://github.com/amzxyz/rime-wanxiang/releases/download/${WANXIANG_TAG}/${BASE_ASSET_NAME}"
GRAMMAR_URL="https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/${GRAMMAR_ASSET_NAME}"

info() {
  printf '==> %s\n' "$1"
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

download_if_needed() {
  local url="$1"
  local output="$2"
  local expected_sha="$3"

  if [[ -f "${output}" ]]; then
    local actual_sha
    actual_sha="$(sha256_file "${output}")"
    if [[ -z "${expected_sha}" || "${actual_sha}" == "${expected_sha}" ]]; then
      info "Using cached $(basename "${output}")"
      return 0
    fi
    rm -f "${output}"
  fi

  info "Downloading $(basename "${output}")"
  curl -fL --retry 3 -o "${output}" "${url}"

  if [[ -n "${expected_sha}" ]]; then
    local actual_sha
    actual_sha="$(sha256_file "${output}")"
    [[ "${actual_sha}" == "${expected_sha}" ]] || fail "$(basename "${output}") sha256 mismatch: ${actual_sha}"
  fi
}

mkdir -p "${WORK_DIR}" "${DEST_DIR}"

BASE_ZIP="${WORK_DIR}/${BASE_ASSET_NAME%.zip}-${WANXIANG_TAG}.zip"
GRAMMAR_FILE="${WORK_DIR}/${GRAMMAR_ASSET_NAME}"
EXPANDED_DIR="${WORK_DIR}/base-expanded"

download_if_needed "${BASE_URL}" "${BASE_ZIP}" "${BASE_ASSET_SHA256}"
download_if_needed "${GRAMMAR_URL}" "${GRAMMAR_FILE}" "${GRAMMAR_ASSET_SHA256}"

ACTUAL_GRAMMAR_SHA256="$(sha256_file "${GRAMMAR_FILE}")"

rm -rf "${EXPANDED_DIR}"
mkdir -p "${EXPANDED_DIR}"
info "Expanding ${BASE_ASSET_NAME}"
unzip -q "${BASE_ZIP}" -d "${EXPANDED_DIR}"
cp "${GRAMMAR_FILE}" "${EXPANDED_DIR}/${GRAMMAR_ASSET_NAME}"

info "Replacing ${DEST_DIR}"
find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
ditto "${EXPANDED_DIR}" "${DEST_DIR}"

info "Writing Rime shared manifest"
python3 - "${DEST_DIR}" "${WANXIANG_TAG}" "${WANXIANG_COMMIT}" "${BASE_ASSET_NAME}" "${BASE_ASSET_SHA256}" "${GRAMMAR_ASSET_NAME}" "${ACTUAL_GRAMMAR_SHA256}" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

dest = Path(sys.argv[1])
tag = sys.argv[2]
commit = sys.argv[3]
base_asset_name = sys.argv[4]
base_asset_sha256 = sys.argv[5]
grammar_asset_name = sys.argv[6]
grammar_asset_sha256 = sys.argv[7]
manifest_name = "rime-shared-manifest.json"

files = []
for path in sorted(dest.rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(dest).as_posix()
    if relative == manifest_name:
        continue
    data = path.read_bytes()
    files.append({
        "path": relative,
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
    })

manifest = {
    "tag": tag,
    "sourceCommit": commit,
    "baseAssetName": base_asset_name,
    "baseAssetSHA256": base_asset_sha256,
    "grammarAssetName": grammar_asset_name,
    "grammarAssetSHA256": grammar_asset_sha256,
    "schemaID": "wanxiang",
    "files": files,
}

(dest / manifest_name).write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

info "Synced $(find "${DEST_DIR}" -type f | wc -l | tr -d ' ') files into SimpaninKeyboard/RimeShared"
