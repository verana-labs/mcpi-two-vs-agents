#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

SOURCE_PROFILE="${1:-agent-a}"
TARGET_PROFILE="${2:-agent-b}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"

if [[ "${DEPLOY_MODE:-k8s}" != "k8s" ]]; then
  echo "link-vs-agents.sh currently supports DEPLOY_MODE=k8s only." >&2
  exit 1
fi

require_command kubectl
require_command curl
require_command jq

capture_profile() {
  local profile_name="$1"
  local prefix="$2"

  load_profile "${profile_name}"
  load_k8s_meta_from_deployment

  local admin_url
  admin_url="$(get_live_k8s_admin_base_url)"
  local agent_json
  agent_json="$(curl -sf "${admin_url}/v1/agent")"

  printf -v "${prefix}_PROFILE" '%s' "${PROFILE_NAME}"
  printf -v "${prefix}_SERVICE_NAME" '%s' "${SERVICE_NAME}"
  printf -v "${prefix}_NAMESPACE" '%s' "${K8S_NAMESPACE}"
  printf -v "${prefix}_RELEASE_NAME" '%s' "${K8S_RELEASE_NAME}"
  printf -v "${prefix}_POD" '%s' "${K8S_RELEASE_NAME}-0"
  printf -v "${prefix}_ADMIN_URL" '%s' "${admin_url}"
  printf -v "${prefix}_PUBLIC_DID" '%s' "$(printf '%s' "${agent_json}" | jq -r '.publicDid')"
  printf -v "${prefix}_LABEL" '%s' "$(printf '%s' "${agent_json}" | jq -r '.label')"
}

latest_target_connection() {
  curl -sf "${TARGET_ADMIN_URL}/v1/connections" | jq -c \
    --arg source_did "${SOURCE_PUBLIC_DID}" \
    --arg source_label "${SOURCE_LABEL}" \
    '
    [ .[]
      | select(.state == "completed")
      | select(.invitationDid == $source_did)
      | select((.theirLabel // $source_label) == $source_label)
    ]
    | sort_by(.updatedAt // .createdAt)
    | last // empty
    '
}

latest_source_connection_for_target_did() {
  local target_peer_did="$1"
  curl -sf "${SOURCE_ADMIN_URL}/v1/connections" | jq -c \
    --arg target_peer_did "${target_peer_did}" \
    --arg target_label "${TARGET_LABEL}" \
    '
    [ .[]
      | select(.state == "completed")
      | select(.theirDid == $target_peer_did)
      | select((.theirLabel // $target_label) == $target_label)
    ]
    | sort_by(.updatedAt // .createdAt)
    | last // empty
    '
}

capture_profile "${SOURCE_PROFILE}" "SOURCE"
capture_profile "${TARGET_PROFILE}" "TARGET"

if [[ "${SOURCE_NAMESPACE}" != "${TARGET_NAMESPACE}" ]]; then
  echo "Source and target are not in the same namespace: ${SOURCE_NAMESPACE} vs ${TARGET_NAMESPACE}" >&2
  exit 1
fi

STATE_LINK_DIR="${DEMO_ROOT}/.state/links"
mkdir -p "${STATE_LINK_DIR}"
STATE_LINK_FILE="${STATE_LINK_DIR}/${SOURCE_PROFILE}__${TARGET_PROFILE}.json"

TARGET_MATCH="$(latest_target_connection || true)"
SOURCE_MATCH=""
if [[ -n "${TARGET_MATCH}" ]]; then
  TARGET_DID="$(printf '%s' "${TARGET_MATCH}" | jq -r '.did')"
  SOURCE_MATCH="$(latest_source_connection_for_target_did "${TARGET_DID}" || true)"
fi

if [[ -n "${TARGET_MATCH}" && -n "${SOURCE_MATCH}" ]]; then
  jq -n \
    --arg sourceProfile "${SOURCE_PROFILE}" \
    --arg targetProfile "${TARGET_PROFILE}" \
    --arg sourceDid "${SOURCE_PUBLIC_DID}" \
    --arg targetDid "${TARGET_PUBLIC_DID}" \
    --argjson sourceConnection "${SOURCE_MATCH}" \
    --argjson targetConnection "${TARGET_MATCH}" \
    '{
      sourceProfile: $sourceProfile,
      targetProfile: $targetProfile,
      sourceVsDid: $sourceDid,
      targetVsDid: $targetDid,
      sourceConnection: $sourceConnection,
      targetConnection: $targetConnection
    }' > "${STATE_LINK_FILE}"
  echo "Direct DIDComm link already present."
  echo "  Source admin   : ${SOURCE_ADMIN_URL}"
  echo "  Target admin   : ${TARGET_ADMIN_URL}"
  echo "  State file     : ${STATE_LINK_FILE}"
  exit 0
fi

SOURCE_INVITATION_URL="$(curl -sf "${SOURCE_ADMIN_URL}/v1/invitation" | jq -r '.url')"
if [[ -z "${SOURCE_INVITATION_URL}" || "${SOURCE_INVITATION_URL}" == "null" ]]; then
  echo "Failed to retrieve invitation URL from ${SOURCE_ADMIN_URL}" >&2
  exit 1
fi

kubectl -n "${TARGET_NAMESPACE}" exec -i "${TARGET_POD}" -- env SOURCE_INVITATION_URL="${SOURCE_INVITATION_URL}" sh -lc 'cat >/tmp/vs-agent-link-bootstrap.js && node /tmp/vs-agent-link-bootstrap.js' < "${DEMO_ROOT}/scripts/lib/vs-agent-link-bootstrap.js"

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
TARGET_MATCH=""
SOURCE_MATCH=""

while [[ "$(date +%s)" -lt "${deadline}" ]]; do
  TARGET_MATCH="$(latest_target_connection || true)"
  if [[ -n "${TARGET_MATCH}" ]]; then
    TARGET_DID="$(printf '%s' "${TARGET_MATCH}" | jq -r '.did')"
    SOURCE_MATCH="$(latest_source_connection_for_target_did "${TARGET_DID}" || true)"
    if [[ -n "${SOURCE_MATCH}" ]]; then
      break
    fi
  fi
  sleep 2
done

if [[ -z "${TARGET_MATCH}" || -z "${SOURCE_MATCH}" ]]; then
  echo "Timed out waiting for direct DIDComm link between ${SOURCE_PROFILE} and ${TARGET_PROFILE}" >&2
  echo "Source admin: ${SOURCE_ADMIN_URL}" >&2
  echo "Target admin: ${TARGET_ADMIN_URL}" >&2
  exit 1
fi

jq -n \
  --arg sourceProfile "${SOURCE_PROFILE}" \
  --arg targetProfile "${TARGET_PROFILE}" \
  --arg sourceDid "${SOURCE_PUBLIC_DID}" \
  --arg targetDid "${TARGET_PUBLIC_DID}" \
  --argjson sourceConnection "${SOURCE_MATCH}" \
  --argjson targetConnection "${TARGET_MATCH}" \
  '{
    sourceProfile: $sourceProfile,
    targetProfile: $targetProfile,
    sourceVsDid: $sourceDid,
    targetVsDid: $targetDid,
    sourceConnection: $sourceConnection,
    targetConnection: $targetConnection
  }' > "${STATE_LINK_FILE}"

echo "Direct DIDComm link established."
echo "  Source profile : ${SOURCE_PROFILE}"
echo "  Target profile : ${TARGET_PROFILE}"
echo "  Source admin   : ${SOURCE_ADMIN_URL}"
echo "  Target admin   : ${TARGET_ADMIN_URL}"
echo "  Source conn id : $(printf '%s' "${SOURCE_MATCH}" | jq -r '.id')"
echo "  Target conn id : $(printf '%s' "${TARGET_MATCH}" | jq -r '.id')"
echo "  State file     : ${STATE_LINK_FILE}"
