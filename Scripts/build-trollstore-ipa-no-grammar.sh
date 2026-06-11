#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INCLUDE_GRAMMAR=0 \
OUTPUT_NAME="${OUTPUT_NAME:-Simpanin-TrollStore-NoGrammar.ipa}" \
bash "${SCRIPT_DIR}/build-trollstore-ipa.sh"
