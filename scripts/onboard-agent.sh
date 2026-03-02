#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

load_profile "${1:-}"

echo "[${PROFILE_NAME}] Running Step 01: deploy VS Agent"
if [[ "${DEPLOY_MODE}" == "k8s" ]]; then
  deploy_vs_k8s
else
  run_verana_step "01-deploy-vs.sh"
fi

echo "[${PROFILE_NAME}] Running Step 02: obtain ECS credentials"
if [[ "${DEPLOY_MODE}" == "k8s" ]]; then
  ensure_k8s_port_forward
fi
run_verana_step "02-get-ecs-credentials.sh"

echo "[${PROFILE_NAME}] Running Step 03: create trust registry"
if [[ "${DEPLOY_MODE}" == "k8s" ]]; then
  ensure_k8s_port_forward
fi
run_verana_step "03-create-trust-registry.sh"

echo "[${PROFILE_NAME}] Completed. IDs file: ${OUTPUT_FILE}"
