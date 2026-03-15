#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"
# shellcheck source=/Users/mathieu/datashare/2060io/verana-demos/scripts/vs-demo/common.sh
source "${VERANA_DEMOS_ROOT:-/Users/mathieu/datashare/2060io/verana-demos}/scripts/vs-demo/common.sh"

usage() {
  cat <<USAGE
Usage: $0 <agent-a|agent-b>

Environment:
  AUTO_FUND=true           Attempt faucet POST if balance is empty.
  FAUCET_POST_URL=<url>    Faucet API endpoint accepting POST {"address":"..."}.
USAGE
}

require_json_field() {
  local json="$1"
  local jq_expr="$2"
  local value
  value="$(echo "$json" | jq -r "$jq_expr")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    return 1
  fi
  printf '%s\n' "$value"
}

ensure_key_and_balance() {
  if ! veranad keys show "$USER_ACC" --keyring-backend test >/dev/null 2>&1; then
    log "Creating keyring account ${USER_ACC}"
    veranad keys add "$USER_ACC" --keyring-backend test >/dev/null
  fi

  USER_ACC_ADDR="$(veranad keys show "$USER_ACC" -a --keyring-backend test)"
  export USER_ACC_ADDR
  ok "Using account ${USER_ACC} (${USER_ACC_ADDR})"

  if check_balance "$USER_ACC"; then
    return 0
  fi

  if [[ "${AUTO_FUND:-false}" != "true" ]]; then
    err "Account ${USER_ACC} is unfunded. Fund ${USER_ACC_ADDR} and re-run."
    return 1
  fi

  if [[ -z "${FAUCET_POST_URL:-}" ]]; then
    err "AUTO_FUND=true requires FAUCET_POST_URL"
    return 1
  fi

  log "Requesting faucet funds from ${FAUCET_POST_URL}"
  curl -fsS -X POST "$FAUCET_POST_URL" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg address "$USER_ACC_ADDR" '{address: $address}')" >/dev/null

  sleep 8
  check_balance "$USER_ACC"
}

get_admin_api() {
  if [[ "$DEPLOY_MODE" == "k8s" ]]; then
    load_k8s_meta_from_deployment
    printf '%s\n' "$(get_live_k8s_admin_base_url)"
  else
    printf 'http://127.0.0.1:%s\n' "$VS_AGENT_ADMIN_PORT"
  fi
}

get_public_base() {
  if [[ "$DEPLOY_MODE" == "k8s" ]]; then
    load_k8s_meta_from_deployment
    if [[ -n "${K8S_INGRESS_HOST:-}" ]]; then
      printf 'https://%s\n' "$K8S_INGRESS_HOST"
      return 0
    fi
  fi
  printf 'http://127.0.0.1:%s\n' "$VS_AGENT_PUBLIC_PORT"
}

save_ids() {
  local output_file="$1"
  local cs_org_id="$2"
  local cs_service_id="$3"
  local issuer_perm_service="$4"
  local agent_did="$5"
  local admin_api="$6"

  mkdir -p "$(dirname "$output_file")"
  touch "$output_file"
  sed -i.bak '/^# ECS Credentials/,/^$/d' "$output_file" 2>/dev/null || true
  rm -f "${output_file}.bak"

  if ! rg -q '^AGENT_DID=' "$output_file"; then
    cat >> "$output_file" <<BASE
# VS Demo — Resource IDs
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Network: ${NETWORK}
# Mode: ${DEPLOY_MODE}

AGENT_DID=${agent_did}
VS_AGENT_ADMIN_URL=${admin_api}
VS_AGENT_ADMIN_PORT=${VS_AGENT_ADMIN_PORT}
VS_AGENT_PUBLIC_PORT=${VS_AGENT_PUBLIC_PORT}
USER_ACC=${USER_ACC}
BASE
  fi

  cat >> "$output_file" <<EOF_IDS

# ECS Credentials
CS_ORG_ID=${cs_org_id}
CS_SERVICE_ID=${cs_service_id}
ISSUER_PERM_SERVICE=${issuer_perm_service}
EOF_IDS
}

main() {
  local profile_name="${1:-}"
  if [[ -z "$profile_name" ]]; then
    usage
    exit 1
  fi

  require_command curl
  require_command jq
  require_command veranad
  load_profile "$profile_name"
  set_network_vars "$NETWORK"

  local admin_api public_base
  admin_api="$(get_admin_api)"
  public_base="$(get_public_base)"

  log "Waiting for VS Agent admin API at ${admin_api}"
  wait_for_agent "$admin_api" 60 || {
    err "VS Agent admin API is not reachable at ${admin_api}"
    exit 1
  }

  ensure_key_and_balance

  local agent_info
  agent_info="$(curl -fsS "${admin_api}/v1/agent")"
  AGENT_DID="$(require_json_field "$agent_info" '.publicDid')"
  ok "Agent DID: ${AGENT_DID}"

  log "Discovering ECS schemas from ${ECS_TR_PUBLIC_URL}"
  local org_vtjsc_output service_vtjsc_output org_jsc_url cs_org_id service_jsc_url cs_service_id
  org_vtjsc_output="$(discover_ecs_vtjsc "$ECS_TR_PUBLIC_URL" organization)"
  org_jsc_url="$(echo "$org_vtjsc_output" | sed -n '1p')"
  cs_org_id="$(echo "$org_vtjsc_output" | sed -n '2p')"
  service_vtjsc_output="$(discover_ecs_vtjsc "$ECS_TR_PUBLIC_URL" service)"
  service_jsc_url="$(echo "$service_vtjsc_output" | sed -n '1p')"
  cs_service_id="$(echo "$service_vtjsc_output" | sed -n '2p')"
  ok "Organization schema: ${cs_org_id}"
  ok "Service schema: ${cs_service_id}"

  log "Removing previously linked ECS credentials on ${PROFILE_NAME}"
  cleanup_ecs_credentials "$admin_api" "$org_jsc_url" "$service_jsc_url"

  log "Issuing ECS organization credential"
  local org_logo_data_uri service_logo_data_uri org_claims service_claims
  org_logo_data_uri="$(download_logo_data_uri "$ORG_LOGO_URL")"
  service_logo_data_uri="$(download_logo_data_uri "$SERVICE_LOGO_URL")"

  org_claims="$(jq -nc \
    --arg id "$AGENT_DID" \
    --arg name "$ORG_NAME" \
    --arg logo "$org_logo_data_uri" \
    --arg rid "$ORG_REGISTRY_ID" \
    --arg addr "$ORG_ADDRESS" \
    --arg cc "$ORG_COUNTRY" \
    '{id: $id, name: $name, logo: $logo, registryId: $rid, address: $addr, countryCode: $cc}')"

  issue_remote_and_link "$ECS_TR_ADMIN_API" "$admin_api" organization "$org_jsc_url" "$AGENT_DID" "$org_claims"

  log "Ensuring service-schema issuer permission"
  local issuer_perm_service=""
  if issuer_perm_service="$(find_active_issuer_perm "$cs_service_id" "$AGENT_DID")"; then
    ok "Reusing issuer permission ${issuer_perm_service}"
  else
    local effective_from
    effective_from="$(future_timestamp 15)"
    issuer_perm_service="$(submit_tx create_permission permission_id \
      veranad tx perm create-perm "$cs_service_id" issuer "$AGENT_DID" --effective-from "$effective_from")"
    ok "Created issuer permission ${issuer_perm_service}"
    sleep 21
  fi

  log "Issuing ECS service credential"
  service_claims="$(jq -nc \
    --arg id "$AGENT_DID" \
    --arg name "$SERVICE_NAME" \
    --arg type "$SERVICE_TYPE" \
    --arg desc "$SERVICE_DESCRIPTION" \
    --arg logo "$service_logo_data_uri" \
    --argjson age "$SERVICE_MIN_AGE" \
    --arg terms "$SERVICE_TERMS" \
    --arg privacy "$SERVICE_PRIVACY" \
    '{id: $id, name: $name, type: $type, description: $desc, logo: $logo, minimumAgeRequired: $age, termsAndConditions: $terms, privacyPolicy: $privacy}')"

  issue_remote_and_link "$admin_api" "$admin_api" service "$service_jsc_url" "$AGENT_DID" "$service_claims"

  log "Verifying linked VPs in the public DID document"
  local did_doc vp_count
  did_doc="$(curl -fsS "${public_base}/.well-known/did.json")"
  vp_count="$(echo "$did_doc" | jq '[.service[]? | select(.type == "LinkedVerifiablePresentation")] | length')"
  ok "DID document exposes ${vp_count} linked verifiable presentations"

  save_ids "$OUTPUT_FILE" "$cs_org_id" "$cs_service_id" "$issuer_perm_service" "$AGENT_DID" "$admin_api"

  printf '\n%s\n' "ECS onboarding complete for ${PROFILE_NAME}"
  printf '  AGENT_DID: %s\n' "$AGENT_DID"
  printf '  ADMIN_API: %s\n' "$admin_api"
  printf '  PUBLIC_URL: %s\n' "$public_base"
  printf '  CS_ORG_ID: %s\n' "$cs_org_id"
  printf '  CS_SERVICE_ID: %s\n' "$cs_service_id"
  printf '  ISSUER_PERM_SERVICE: %s\n' "$issuer_perm_service"
}

main "$@"
