#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_DIR="${ROOT_DIR}/SimpaninKeyboard/RimeShared"
USER_DIR="${TMPDIR:-/tmp}/simpanin-rime-user-prebuild"
SCHEMA_ID="${SCHEMA_ID:-wanxiang_ios}"
TABLE_NAME="${TABLE_NAME:-wanxiang_ios}"

info() {
  printf '==> %s\n' "$1"
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

find_deployer() {
  if [[ -n "${RIME_DEPLOYER:-}" ]]; then
    [[ -x "${RIME_DEPLOYER}" ]] || fail "RIME_DEPLOYER is set but not executable: ${RIME_DEPLOYER}"
    printf '%s\n' "${RIME_DEPLOYER}"
    return 0
  fi

  if command -v rime_deployer >/dev/null 2>&1; then
    command -v rime_deployer
    return 0
  fi

  for candidate in \
    /opt/homebrew/bin/rime_deployer \
    /usr/local/bin/rime_deployer; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  fail "未找到 rime_deployer。请先执行：brew install librime；或设置 RIME_DEPLOYER=/path/to/rime_deployer"
}

build_dir_is_complete() {
  local build_dir="$1"
  local file

  [[ -d "${build_dir}" ]] || return 1
  for file in "${required[@]}"; do
    [[ -f "${build_dir}/${file}" ]] || return 1
  done
}

update_manifest() {
  info "Updating rime-shared-manifest.json"
  python3 - "${SHARED_DIR}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

dest = Path(sys.argv[1])
manifest_path = dest / "rime-shared-manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

files = []
for path in sorted(dest.rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(dest).as_posix()
    if relative == manifest_path.name:
        continue
    data = path.read_bytes()
    files.append({
        "path": relative,
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
    })

manifest["files"] = files
manifest_path.write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

[[ -d "${SHARED_DIR}" ]] || fail "RimeShared not found: ${SHARED_DIR}"
[[ -f "${SHARED_DIR}/default.yaml" ]] || fail "Missing default.yaml in ${SHARED_DIR}"
[[ -f "${SHARED_DIR}/${SCHEMA_ID}.schema.yaml" ]] || fail "Missing schema: ${SHARED_DIR}/${SCHEMA_ID}.schema.yaml"

DEPLOYER="$(find_deployer)"
info "Using deployer: ${DEPLOYER}"

rm -rf "${USER_DIR}"
mkdir -p "${USER_DIR}"

required=(
  "${SCHEMA_ID}.schema.yaml"
  "${SCHEMA_ID}.prism.bin"
  "${TABLE_NAME}.table.bin"
)

info "Deploying ${SCHEMA_ID} into temporary user dir: ${USER_DIR}"
rm -rf "${SHARED_DIR}/build"
if ! "${DEPLOYER}" --build "${SHARED_DIR}" "${USER_DIR}"; then
  if ! build_dir_is_complete "${SHARED_DIR}/build"; then
    fail "rime_deployer 执行失败且未生成完整 build 产物。请运行 '${DEPLOYER}' 检查本机参数格式。"
  fi
fi

if build_dir_is_complete "${USER_DIR}/build"; then
  info "Copying build products into SimpaninKeyboard/RimeShared/build"
  rm -rf "${SHARED_DIR}/build"
  cp -R "${USER_DIR}/build" "${SHARED_DIR}/build"
elif build_dir_is_complete "${SHARED_DIR}/build"; then
  info "Build products were generated in SimpaninKeyboard/RimeShared/build"
else
  for file in "${required[@]}"; do
    [[ -f "${SHARED_DIR}/build/${file}" ]] || fail "缺少部署产物：build/${file}"
  done
fi

update_manifest

info "Done. Required products:"
for file in "${required[@]}"; do
  ls -lh "${SHARED_DIR}/build/${file}"
done
