#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NETWORK="${NETWORK:-testnet}"
K8S_NAMESPACE="${K8S_NAMESPACE:-vna-${NETWORK}-1}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://ollama-tunnel.invalid}"
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
require_command sed

kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${K8S_NAMESPACE}" create configmap mcpi-controller-app \
  --from-file=package.json="${DEMO_ROOT}/controller/package.json" \
  --from-file=index.js="${DEMO_ROOT}/controller/src/index.js" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${K8S_NAMESPACE}" create configmap mcpi-controller-runtime \
  --from-literal=OLLAMA_BASE_URL="${OLLAMA_BASE_URL}" \
  --from-literal=OLLAMA_MODEL="${OLLAMA_MODEL}" \
  --from-literal=MCPI_ENV="${MCPI_ENV}" \
  --from-literal=MCPI_AUDIT_ENABLED="${MCPI_AUDIT_ENABLED}" \
  --dry-run=client -o yaml | kubectl apply -f -

rendered_file="$(mktemp)"
trap 'rm -f "${rendered_file}"' EXIT
sed "s/__NETWORK__/${NETWORK}/g" "${DEMO_ROOT}/k8s/controllers/base.yaml" > "${rendered_file}"
kubectl apply -f "${rendered_file}"

kubectl -n "${K8S_NAMESPACE}" rollout status deploy/mcpi-controller-a --timeout=300s
kubectl -n "${K8S_NAMESPACE}" rollout status deploy/mcpi-controller-b --timeout=300s

kubectl -n "${K8S_NAMESPACE}" set env statefulset/mcpi-agent-a EVENTS_BASE_URL="http://mcpi-controller-a:4101" >/dev/null
kubectl -n "${K8S_NAMESPACE}" set env statefulset/mcpi-agent-b EVENTS_BASE_URL="http://mcpi-controller-b:4102" >/dev/null

echo "Controllers deployed in ${K8S_NAMESPACE}"
echo "  Internal A: http://mcpi-controller-a.${K8S_NAMESPACE}.svc.cluster.local:4101"
echo "  Internal B: http://mcpi-controller-b.${K8S_NAMESPACE}.svc.cluster.local:4102"
echo "  External A: https://mcpi-controller-a.${NETWORK}.verana.network"
echo "  External B: https://mcpi-controller-b.${NETWORK}.verana.network"
echo "  Ollama URL : ${OLLAMA_BASE_URL}"
