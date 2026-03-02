#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

load_profile "${1:-}"

if [[ "${DEPLOY_MODE}" == "k8s" ]]; then
  deploy_vs_k8s
else
  run_verana_step "01-deploy-vs.sh"
fi
