#!/usr/bin/env bash

set -euo pipefail

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
}

fix_rendered_manifest() {
  local input_file="$1"
  local output_file="$2"
  awk '
    function leading_spaces(s,   i, c) {
      c = 0
      for (i = 1; i <= length(s); i++) {
        if (substr(s, i, 1) == " ") c++
        else break
      }
      return c
    }
    {
      line = $0
      indent = leading_spaces(line)

      if (in_resources) {
        if (line ~ /^[[:space:]]*$/) {
          print line
          next
        }
        # Workaround: chart v1.7.3 emits container resources children at the
        # same indentation as "resources:". Shift the whole resources subtree
        # by two spaces to restore valid Kubernetes YAML.
        if (indent > resources_indent || (indent == resources_indent && ($1 == "limits:" || $1 == "requests:"))) {
          print "  " line
          next
        }
        in_resources = 0
      }

      if (line ~ /^---[[:space:]]*$/) {
        in_workload = 0
        in_containers = 0
      }

      if (line ~ /^[[:space:]]*kind:[[:space:]]*(StatefulSet|Deployment|DaemonSet|Job|CronJob)[[:space:]]*$/) {
        in_workload = 1
      }

      if (in_workload && line ~ /^[[:space:]]*containers:[[:space:]]*$/) {
        in_containers = 1
        containers_indent = indent
      } else if (in_containers && line !~ /^[[:space:]]*$/ && (indent < containers_indent || (indent == containers_indent && line !~ /^[[:space:]]*-[[:space:]]/))) {
        in_containers = 0
      }

      # Workaround: normalize malformed container resources section emitted by
      # vs-agent-chart v1.7.3 (it renders limits/requests at container root).
      if (in_containers && line ~ /^[[:space:]]*resources:[[:space:]]*$/) {
        resources_indent = leading_spaces(line)
        in_resources = 1
      }

      print line
    }
  ' "${input_file}" > "${output_file}"
}

render_profile_deployment() {
  K8S_RENDERED_DEPLOYMENT="${STATE_DIR}/deployment.resolved.yaml"
  sed "s/__NETWORK__/${NETWORK}/g" "${PROFILE_DIR}/deployment.yaml" > "${K8S_RENDERED_DEPLOYMENT}"
  export K8S_RENDERED_DEPLOYMENT
}

load_k8s_meta_from_deployment() {
  render_profile_deployment

  K8S_CHART_SOURCE="$(sed -nE 's/^chartSource:[[:space:]]*//p' "${K8S_RENDERED_DEPLOYMENT}" | head -n 1)"
  K8S_CHART_VERSION="$(sed -nE 's/^chartVersion:[[:space:]]*//p' "${K8S_RENDERED_DEPLOYMENT}" | head -n 1)"
  K8S_NAMESPACE="$(sed -nE 's/^chartNamespace:[[:space:]]*//p' "${K8S_RENDERED_DEPLOYMENT}" | head -n 1)"
  K8S_RELEASE_NAME="$(sed -nE 's/^name:[[:space:]]*//p' "${K8S_RENDERED_DEPLOYMENT}" | head -n 1)"
  K8S_INGRESS_HOST="$(sed -nE 's/^[[:space:]]*host:[[:space:]]*"?([^"]*)"?/\1/p' "${K8S_RENDERED_DEPLOYMENT}" | head -n 1)"

  if [[ -z "${K8S_CHART_SOURCE:-}" || -z "${K8S_CHART_VERSION:-}" || -z "${K8S_NAMESPACE:-}" || -z "${K8S_RELEASE_NAME:-}" ]]; then
    echo "Could not parse chart metadata from ${K8S_RENDERED_DEPLOYMENT}" >&2
    exit 1
  fi

  export K8S_CHART_SOURCE K8S_CHART_VERSION K8S_NAMESPACE K8S_RELEASE_NAME K8S_INGRESS_HOST
}

build_k8s_values_file() {
  K8S_VALUES_FILE="${STATE_DIR}/helm-values.yaml"
  local base_values_file="${STATE_DIR}/helm-values.base.yaml"

  awk '
    !/^chartSource:/ &&
    !/^chartVersion:/ &&
    !/^chartNamespace:/
  ' "${K8S_RENDERED_DEPLOYMENT}" > "${base_values_file}"
  cp "${base_values_file}" "${K8S_VALUES_FILE}"

  export K8S_VALUES_FILE
}

wait_for_admin_api() {
  local retries="${1:-60}"
  local i=0
  local admin_url="http://127.0.0.1:${VS_AGENT_ADMIN_PORT}/v1/agent"
  while [[ $i -lt "$retries" ]]; do
    if curl -sf "$admin_url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  return 1
}

stop_k8s_port_forward() {
  local pid_file="${STATE_DIR}/k8s-port-forward.pid"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "${pid}" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pid_file"
  fi
}

start_k8s_port_forward() {
  require_command kubectl
  load_k8s_meta_from_deployment

  stop_k8s_port_forward

  local log_file="${STATE_DIR}/k8s-port-forward.log"
  : > "$log_file"

  kubectl -n "${K8S_NAMESPACE}" port-forward "svc/${K8S_RELEASE_NAME}" \
    "${VS_AGENT_ADMIN_PORT}:3000" "${VS_AGENT_PUBLIC_PORT}:3001" >"${log_file}" 2>&1 &
  local pf_pid=$!
  echo "$pf_pid" > "${STATE_DIR}/k8s-port-forward.pid"

  if ! wait_for_admin_api 60; then
    echo "Port-forward failed for ${K8S_RELEASE_NAME} in ${K8S_NAMESPACE}. See ${log_file}" >&2
    stop_k8s_port_forward
    exit 1
  fi
}

ensure_k8s_port_forward() {
  if ! curl -sf "http://127.0.0.1:${VS_AGENT_ADMIN_PORT}/v1/agent" >/dev/null 2>&1; then
    start_k8s_port_forward
  fi
}

write_k8s_step01_output() {
  local agent_did="$1"
  local public_url=""
  if [[ -n "${K8S_INGRESS_HOST:-}" ]]; then
    public_url="https://${K8S_INGRESS_HOST}"
  fi

  cat > "${OUTPUT_FILE}" <<EOF
# VS Demo — Resource IDs
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Network: ${NETWORK}
# Mode: k8s

# VS Agent
AGENT_DID=${agent_did}
NGROK_URL=${public_url}
VS_AGENT_CONTAINER_NAME=${K8S_RELEASE_NAME}
VS_AGENT_ADMIN_PORT=${VS_AGENT_ADMIN_PORT}
VS_AGENT_PUBLIC_PORT=${VS_AGENT_PUBLIC_PORT}
USER_ACC=${USER_ACC}
K8S_NAMESPACE=${K8S_NAMESPACE}
K8S_RELEASE_NAME=${K8S_RELEASE_NAME}
K8S_INGRESS_HOST=${K8S_INGRESS_HOST}
EOF
}

deploy_vs_k8s() {
  require_command helm
  require_command kubectl
  require_command curl
  require_command jq

  load_k8s_meta_from_deployment
  build_k8s_values_file

  local current_context
  current_context="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "${current_context}" ]]; then
    echo "No active kubectl context. Configure kubeconfig first." >&2
    exit 1
  fi

  local helm_short_version
  helm_short_version="$(helm version --short 2>/dev/null || true)"

  if [[ "${helm_short_version}" == v4* ]]; then
    local rendered_raw="${STATE_DIR}/helm-rendered.raw.yaml"
    local rendered_fixed="${STATE_DIR}/helm-rendered.fixed.yaml"

    helm template "${K8S_RELEASE_NAME}" "${K8S_CHART_SOURCE}" \
      --version "${K8S_CHART_VERSION}" \
      --namespace "${K8S_NAMESPACE}" \
      --values "${K8S_VALUES_FILE}" \
      --set-string "didcommLabel=${SERVICE_NAME}" \
      --set-string "didcommInvitationImageUrl=${SERVICE_LOGO_URL}" > "${rendered_raw}"

    fix_rendered_manifest "${rendered_raw}" "${rendered_fixed}"
    kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "${K8S_NAMESPACE}" apply -f "${rendered_fixed}"
    kubectl -n "${K8S_NAMESPACE}" rollout status "statefulset/${K8S_RELEASE_NAME}" --timeout=300s
  else
    local k8s_post_renderer
    k8s_post_renderer="${STATE_DIR}/helm-post-renderer.sh"
    cat > "${k8s_post_renderer}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"$(command -v bash)" -lc 'source "${SCRIPT_DIR}/k8s.sh"; fix_rendered_manifest /dev/stdin /dev/stdout'
EOF
    chmod +x "${k8s_post_renderer}"

    helm upgrade --install "${K8S_RELEASE_NAME}" "${K8S_CHART_SOURCE}" \
      --version "${K8S_CHART_VERSION}" \
      --namespace "${K8S_NAMESPACE}" --create-namespace \
      --values "${K8S_VALUES_FILE}" \
      --post-renderer "${k8s_post_renderer}" \
      --set-string "didcommLabel=${SERVICE_NAME}" \
      --set-string "didcommInvitationImageUrl=${SERVICE_LOGO_URL}" \
      --wait --timeout 300s
  fi

  start_k8s_port_forward

  local agent_did
  agent_did="$(curl -sf "http://127.0.0.1:${VS_AGENT_ADMIN_PORT}/v1/agent" | jq -r '.publicDid // empty')"
  if [[ -z "${agent_did}" ]]; then
    echo "Could not retrieve AGENT_DID from admin API after deploy." >&2
    exit 1
  fi

  write_k8s_step01_output "$agent_did"

  echo "[${PROFILE_NAME}] k8s Step 01 complete"
  echo "  Context         : ${current_context}"
  echo "  Namespace/Rel   : ${K8S_NAMESPACE}/${K8S_RELEASE_NAME}"
  echo "  AGENT_DID       : ${agent_did}"
  echo "  Admin API (pf)  : http://127.0.0.1:${VS_AGENT_ADMIN_PORT}"
  echo "  Public API (pf) : http://127.0.0.1:${VS_AGENT_PUBLIC_PORT}"
  echo "  IDs file        : ${OUTPUT_FILE}"
}
