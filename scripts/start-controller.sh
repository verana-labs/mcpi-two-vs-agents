#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"

node_binary_works() {
  local node_bin="${1:?missing node path}"
  # Use Perl alarm to avoid hanging on broken Node installs.
  perl -e 'alarm shift @ARGV; exec @ARGV' 3 "${node_bin}" --version >/dev/null 2>&1
}

resolve_node_bin() {
  local candidate=""
  local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
  local nvm_default_alias="${nvm_dir}/alias/default"

  if [[ -n "${NODE_BIN:-}" ]]; then
    if [[ ! -x "${NODE_BIN}" ]]; then
      echo "NODE_BIN is set but not executable: ${NODE_BIN}" >&2
      return 1
    fi

    if node_binary_works "${NODE_BIN}"; then
      echo "${NODE_BIN}"
      return 0
    fi

    echo "NODE_BIN is set but failed to execute: ${NODE_BIN}" >&2
    return 1
  fi

  if [[ -f "${nvm_default_alias}" ]]; then
    candidate="$(tr -d '[:space:]' < "${nvm_default_alias}")"
    candidate="${nvm_dir}/versions/node/${candidate}/bin/node"
    if [[ -x "${candidate}" ]] && node_binary_works "${candidate}"; then
      echo "${candidate}"
      return 0
    fi
  fi

  candidate="$(
    ls -1 "${nvm_dir}/versions/node"/v*/bin/node 2>/dev/null \
      | sort -V \
      | tail -n 1 \
      || true
  )"
  if [[ -n "${candidate}" ]] && [[ -x "${candidate}" ]] && node_binary_works "${candidate}"; then
    echo "${candidate}"
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    candidate="$(command -v node)"
    if node_binary_works "${candidate}"; then
      echo "${candidate}"
      return 0
    fi
  fi

  return 1
}

load_profile "${1:-}"

CONTROLLER_DIR="${DEMO_ROOT}/controller"
if [[ ! -d "${CONTROLLER_DIR}/node_modules" ]]; then
  echo "Missing controller dependencies. Run:" >&2
  echo "  cd ${CONTROLLER_DIR} && npm install" >&2
  exit 1
fi

if lsof -tiTCP:"${CONTROLLER_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Controller port ${CONTROLLER_PORT} already in use. Stop old process or change CONTROLLER_PORT." >&2
  exit 1
fi

export PORT="${CONTROLLER_PORT}"
export AGENT_NAME="${SERVICE_NAME}"
export VS_AGENT_ADMIN_URL="http://127.0.0.1:${VS_AGENT_ADMIN_PORT}"
export PEER_MCPI_URL="${PEER_MCPI_URL}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
export OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
export MCPI_ENV="${MCPI_ENV:-development}"
export MCPI_AUDIT_ENABLED="${MCPI_AUDIT_ENABLED:-true}"
export MCPI_IDENTITY_PATH="${STATE_DIR}/mcpi-identity"
export PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://127.0.0.1:${CONTROLLER_PORT}}"

NODE_EXECUTABLE="$(resolve_node_bin || true)"
if [[ -z "${NODE_EXECUTABLE}" ]]; then
  echo "Unable to find a working Node.js runtime." >&2
  echo "Tip: install/use nvm and run 'nvm use', or set NODE_BIN=/absolute/path/to/node." >&2
  exit 1
fi

cd "${CONTROLLER_DIR}"
echo "[${PROFILE_NAME}] Starting controller on :${CONTROLLER_PORT} with ${NODE_EXECUTABLE} ($("${NODE_EXECUTABLE}" --version))"
exec "${NODE_EXECUTABLE}" src/index.js
