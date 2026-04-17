#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER="${SCRIPT_DIR}/wg-setup.sh"

if [[ ! -x "${CONTROLLER}" ]]; then
  CONTROLLER="$(command -v wg-setup.sh 2>/dev/null || true)"
fi

if [[ -z "${CONTROLLER}" ]]; then
  echo "找不到 wg-setup.sh，请先把控制器脚本放到同目录或 PATH 中。" >&2
  exit 1
fi

exec "${CONTROLLER}" add-peer "$@"
