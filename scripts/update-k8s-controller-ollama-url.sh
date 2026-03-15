#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <ollama-base-url>" >&2
  echo "Example: $0 https://0345649d4e9389.lhr.life" >&2
  exit 1
fi

OLLAMA_BASE_URL="$1"
K8S_NAMESPACE="${K8S_NAMESPACE:-vna-testnet-1}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
MCPI_ENV="${MCPI_ENV:-development}"
MCPI_AUDIT_ENABLED="${MCPI_AUDIT_ENABLED:-true}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_command kubectl
require_command curl

if ! curl -sf --max-time 10 "${OLLAMA_BASE_URL}/api/tags" >/dev/null; then
  echo "Ollama URL is not reachable: ${OLLAMA_BASE_URL}" >&2
  exit 1
fi

kubectl -n "${K8S_NAMESPACE}" create configmap mcpi-controller-runtime \
  --from-literal=OLLAMA_BASE_URL="${OLLAMA_BASE_URL}" \
  --from-literal=OLLAMA_MODEL="${OLLAMA_MODEL}" \
  --from-literal=MCPI_ENV="${MCPI_ENV}" \
  --from-literal=MCPI_AUDIT_ENABLED="${MCPI_AUDIT_ENABLED}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${K8S_NAMESPACE}" rollout restart deployment/mcpi-controller-a deployment/mcpi-controller-b
kubectl -n "${K8S_NAMESPACE}" rollout status deployment/mcpi-controller-a --timeout=300s
kubectl -n "${K8S_NAMESPACE}" rollout status deployment/mcpi-controller-b --timeout=300s

echo "Updated controller Ollama URL in ${K8S_NAMESPACE}"
echo "  OLLAMA_BASE_URL=${OLLAMA_BASE_URL}"
