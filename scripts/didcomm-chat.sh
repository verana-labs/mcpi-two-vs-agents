#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

usage() {
  cat <<USAGE
Usage: $0 <agent-a|agent-b> [--message "hello"] [--legacy] [--allow-untrusted]

Optional environment:
  CLIENT_PUBLIC_ENDPOINT=https://<public-host>
  CLIENT_LISTEN_PORT=4040
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

profile_name="$1"
shift
load_profile "$profile_name"

if [[ "$DEPLOY_MODE" == "k8s" ]]; then
  load_k8s_meta_from_deployment
  invitation_base="$(get_live_k8s_admin_base_url)"
else
  invitation_base="http://127.0.0.1:${VS_AGENT_ADMIN_PORT}"
fi

client_dir="${DEMO_ROOT}/didcomm-client"
if [[ ! -d "${client_dir}/node_modules" ]]; then
  npm --prefix "$client_dir" install
fi

cmd=(
  npm --prefix "$client_dir" run chat --
  --network "$NETWORK"
  --agent-label "MCPI Terminal Client (${PROFILE_NAME})"
  --invitation-endpoint "${invitation_base}/v1/invitation"
  --listen-port "${CLIENT_LISTEN_PORT:-4040}"
)

if [[ -n "${CLIENT_PUBLIC_ENDPOINT:-}" ]]; then
  cmd+=(--public-endpoint "${CLIENT_PUBLIC_ENDPOINT}")
fi

cmd+=("$@")

exec "${cmd[@]}"
