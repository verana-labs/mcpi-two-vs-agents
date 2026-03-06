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
echo "Started controllers:"
echo "  agent-a pid=${PID_A}"
echo "  agent-b pid=${PID_B}"

while true; do
  if ! kill -0 "${PID_A}" 2>/dev/null; then
    wait "${PID_A}" || RC_A=$?
    RC_A="${RC_A:-0}"
    echo "agent-a exited with code ${RC_A}. Stopping agent-b." >&2
    kill "${PID_B}" 2>/dev/null || true
    wait "${PID_B}" 2>/dev/null || true
    exit "${RC_A}"
  fi

  if ! kill -0 "${PID_B}" 2>/dev/null; then
    wait "${PID_B}" || RC_B=$?
    RC_B="${RC_B:-0}"
    echo "agent-b exited with code ${RC_B}. Stopping agent-a." >&2
    kill "${PID_A}" 2>/dev/null || true
    wait "${PID_A}" 2>/dev/null || true
    exit "${RC_B}"
  fi

  sleep 1
done
