#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/start-controller.sh" agent-a &
PID_A=$!
"${SCRIPT_DIR}/start-controller.sh" agent-b &
PID_B=$!

cleanup() {
  kill "${PID_A}" "${PID_B}" 2>/dev/null || true
}

trap cleanup INT TERM EXIT
wait
