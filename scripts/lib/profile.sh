#!/usr/bin/env bash

set -euo pipefail

PROFILE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${PROFILE_LIB_DIR}/../.." && pwd)"
VERANA_DEMOS_ROOT="${VERANA_DEMOS_ROOT:-/Users/mathieu/datashare/2060io/verana-demos}"

usage_profile() {
  cat <<USAGE
Usage: $0 <agent-a|agent-b>
USAGE
}

load_profile() {
  local profile_name="${1:-}"
  if [[ -z "${profile_name}" ]]; then
    usage_profile
    exit 1
  fi

  PROFILE_NAME="${profile_name}"
  PROFILE_DIR="${DEMO_ROOT}/profiles/${PROFILE_NAME}"

  if [[ ! -d "${PROFILE_DIR}" ]]; then
    echo "Profile not found: ${PROFILE_DIR}" >&2
    exit 1
  fi

  if [[ ! -f "${PROFILE_DIR}/config.env" ]]; then
    echo "Missing profile config: ${PROFILE_DIR}/config.env" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${PROFILE_DIR}/config.env"
  set +a

  export PROFILE_NAME PROFILE_DIR
  export NETWORK="${NETWORK:-testnet}"
  export DEPLOY_MODE="${DEPLOY_MODE:-local}"

  STATE_DIR="${DEMO_ROOT}/.state/${PROFILE_NAME}"
  export STATE_DIR

  export VS_AGENT_DATA_DIR="${VS_AGENT_DATA_DIR:-${STATE_DIR}/vs-agent-data}"
  export OUTPUT_FILE="${OUTPUT_FILE:-${STATE_DIR}/vs-ids.env}"
  export VS_IDS_FILE="${VS_IDS_FILE:-${OUTPUT_FILE}}"
  export CUSTOM_SCHEMA_FILE="${CUSTOM_SCHEMA_FILE:-${PROFILE_DIR}/schema.json}"

  mkdir -p "${STATE_DIR}" "${VS_AGENT_DATA_DIR}"
}

run_verana_step() {
  local step_script="${1:?missing script name}"
  local script_path="${VERANA_DEMOS_ROOT}/scripts/vs-demo/${step_script}"

  if [[ ! -f "${script_path}" ]]; then
    echo "Missing verana-demos script: ${script_path}" >&2
    exit 1
  fi

  bash "${script_path}"
}
