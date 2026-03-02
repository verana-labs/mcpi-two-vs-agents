#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"

load_profile "${1:-}"

CONTROLLER_DIR="${DEMO_ROOT}/controller"
if [[ ! -d "${CONTROLLER_DIR}/node_modules" ]]; then
  echo "Missing controller dependencies. Run:" >&2
  echo "  cd ${CONTROLLER_DIR} && npm install" >&2
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

cd "${CONTROLLER_DIR}"
exec node src/index.js
