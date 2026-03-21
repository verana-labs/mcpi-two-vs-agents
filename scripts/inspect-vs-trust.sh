#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/Users/mathieu/datashare/2060io/verana-demos/scripts/vs-demo/common.sh
source "${VERANA_DEMOS_ROOT:-/Users/mathieu/datashare/2060io/verana-demos}/scripts/vs-demo/common.sh"

usage() {
  cat <<'USAGE'
Usage: inspect-vs-trust.sh <public-base-url> [--network testnet|devnet] [--skip-digest-sri]

Examples:
  ./scripts/inspect-vs-trust.sh https://mcpi-agent-a.testnet.verana.network
  ./scripts/inspect-vs-trust.sh https://mcpi-agent-a.testnet.verana.network --skip-digest-sri

What it does:
  1. Fetches the DID Document from the public base URL.
  2. Lists LinkedVerifiablePresentation endpoints.
  3. Inspects the service VP and the referenced JsonSchemaCredential (JSC).
  4. Computes raw and canonicalized schema digests.
  5. Runs strict or relaxed verre trust resolution.

The script prints the exact commands it is running so you can replay each step manually.
USAGE
}

require_local_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command not found: $1"
    exit 1
  fi
}

require_local_command python3
require_local_command jq
require_local_command curl

NETWORK="testnet"
SKIP_DIGEST_SRI="false"
PUBLIC_BASE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      NETWORK="${2:-}"
      shift 2
      ;;
    --skip-digest-sri)
      SKIP_DIGEST_SRI="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$PUBLIC_BASE_URL" ]]; then
        PUBLIC_BASE_URL="$1"
        shift
      else
        err "Unknown argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$PUBLIC_BASE_URL" ]]; then
  usage
  exit 1
fi

set_network_vars "$NETWORK"

DIDCOMM_CLIENT_DIR="${SCRIPT_DIR}/../didcomm-client"
if [[ ! -d "${DIDCOMM_CLIENT_DIR}/node_modules" ]]; then
  log "Installing didcomm-client dependencies"
  npm --prefix "$DIDCOMM_CLIENT_DIR" install >/dev/null
  ok "didcomm-client dependencies installed"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

print_cmd() {
  echo -e "    \033[0;36m$1\033[0m" >&2
}

run_and_capture() {
  local outfile="$1"
  shift
  print_cmd "$*"
  "$@" >"$outfile"
}

step_header() {
  log "$1"
}

show_json_file() {
  local file="$1"
  if jq . "$file" >/dev/null 2>&1; then
    jq . "$file"
  else
    cat "$file"
  fi
}

PUBLIC_BASE_URL="${PUBLIC_BASE_URL%/}"
DID_URL="${PUBLIC_BASE_URL}/.well-known/did.json"

step_header "Step 1: Fetch DID Document"
run_and_capture "${tmpdir}/did.json" curl -sS "$DID_URL"
ok "Fetched DID Document from ${DID_URL}"
echo "Command used:"
print_cmd "curl -sS ${DID_URL}"
echo "Output:"
show_json_file "${tmpdir}/did.json"

AGENT_DID="$(jq -r '.id' "${tmpdir}/did.json")"
if [[ -z "$AGENT_DID" || "$AGENT_DID" == "null" ]]; then
  err "Could not extract DID from DID document"
  exit 1
fi
ok "Resolved DID: ${AGENT_DID}"

step_header "Step 2: List LinkedVerifiablePresentation endpoints"
echo "Command used:"
print_cmd "curl -sS ${DID_URL} | jq '.service[] | select(.type==\"LinkedVerifiablePresentation\") | {id,serviceEndpoint}'"
echo "Output:"
jq '.service[] | select(.type=="LinkedVerifiablePresentation") | {id,serviceEndpoint}' "${tmpdir}/did.json"

SERVICE_VP_URL="$(jq -r '.service[] | select(.type=="LinkedVerifiablePresentation") | select(.id | test("service-c-vp$|whois$")) | .serviceEndpoint' "${tmpdir}/did.json" | head -1)"
ORG_VP_URL="$(jq -r '.service[] | select(.type=="LinkedVerifiablePresentation") | select(.id | test("organization-c-vp$")) | .serviceEndpoint' "${tmpdir}/did.json" | head -1)"

if [[ -z "$SERVICE_VP_URL" ]]; then
  err "Could not find a service LinkedVerifiablePresentation endpoint in DID document"
  exit 1
fi
ok "Service VP endpoint: ${SERVICE_VP_URL}"
if [[ -n "$ORG_VP_URL" ]]; then
  ok "Organization VP endpoint: ${ORG_VP_URL}"
fi

step_header "Step 3: Inspect service Verifiable Presentation"
run_and_capture "${tmpdir}/service-vp.json" curl -sS "$SERVICE_VP_URL"
echo "Command used:"
print_cmd "curl -sS ${SERVICE_VP_URL}"
echo "Extracted summary:"
jq '{vp_id:.id, vp_type:.type, credential_id:.verifiableCredential[0].id, credential_schema_id:.verifiableCredential[0].credentialSchema.id, service_name:.verifiableCredential[0].credentialSubject.name, issuanceDate:.verifiableCredential[0].issuanceDate}' "${tmpdir}/service-vp.json"

JSC_URL="$(jq -r '.verifiableCredential[0].credentialSchema.id' "${tmpdir}/service-vp.json")"
if [[ -z "$JSC_URL" || "$JSC_URL" == "null" ]]; then
  err "Could not extract credentialSchema.id from service VP"
  exit 1
fi
ok "Agent service credential references JSC: ${JSC_URL}"

step_header "Step 4: Inspect JsonSchemaCredential"
run_and_capture "${tmpdir}/jsc.json" curl -sS "$JSC_URL"
echo "Command used:"
print_cmd "curl -sS ${JSC_URL}"
echo "Extracted summary:"
jq '{jsc_id:.id, schema_ref:.credentialSubject.jsonSchema["$ref"], expected_digest:.credentialSubject.digestSRI, issuanceDate}' "${tmpdir}/jsc.json"

SCHEMA_REF="$(jq -r '.credentialSubject.jsonSchema["$ref"]' "${tmpdir}/jsc.json")"
EXPECTED_DIGEST="$(jq -r '.credentialSubject.digestSRI' "${tmpdir}/jsc.json")"
if [[ -z "$SCHEMA_REF" || "$SCHEMA_REF" == "null" ]]; then
  err "Could not extract schema ref from JSC"
  exit 1
fi
ok "Schema ref: ${SCHEMA_REF}"
ok "Expected digest: ${EXPECTED_DIGEST}"

if [[ "$SCHEMA_REF" =~ ^vpr:verana:([^/]+)/cs/v1/js/([0-9]+)$ ]]; then
  SCHEMA_CHAIN_ID="${BASH_REMATCH[1]}"
  SCHEMA_ID="${BASH_REMATCH[2]}"
else
  err "Unsupported schema ref format: ${SCHEMA_REF}"
  exit 1
fi

case "$SCHEMA_CHAIN_ID" in
  vna-testnet-1)
    INDEX_BASE="https://idx.testnet.verana.network/verana"
    API_BASE="https://api.testnet.verana.network/verana"
    ;;
  vna-devnet-1)
    INDEX_BASE="https://idx.devnet.verana.network/verana"
    API_BASE="https://api.devnet.verana.network/verana"
    ;;
  *)
    err "Unsupported chain id in schema ref: ${SCHEMA_CHAIN_ID}"
    exit 1
    ;;
esac

IDX_SCHEMA_URL="${INDEX_BASE}/cs/v1/js/${SCHEMA_ID}"
API_SCHEMA_URL="${API_BASE}/cs/v1/js/${SCHEMA_ID}"

step_header "Step 5: Compute schema digests"
echo "Commands you can replay:"
print_cmd "curl -sS ${IDX_SCHEMA_URL} | openssl dgst -sha384 -binary | openssl base64 -A | sed 's#^#sha384-#'"
print_cmd "curl -sS ${API_SCHEMA_URL} | openssl dgst -sha384 -binary | openssl base64 -A | sed 's#^#sha384-#'"
print_cmd "python3 <canonize and hash ${IDX_SCHEMA_URL}>"

python3 - <<PY
import json, urllib.request, hashlib, base64

idx_url = "${IDX_SCHEMA_URL}"
api_url = "${API_SCHEMA_URL}"
expected = "${EXPECTED_DIGEST}"

idx_raw = urllib.request.urlopen(idx_url).read().decode()
api_raw = urllib.request.urlopen(api_url).read().decode()
api_schema = json.loads(api_raw).get("schema", "")

def sri(content: str) -> str:
    return "sha384-" + base64.b64encode(hashlib.sha384(content.encode()).digest()).decode()

def canon(content: str) -> str:
    return json.dumps(json.loads(content), separators=(",", ":"))

idx_raw_sri = sri(idx_raw)
api_raw_sri = sri(api_raw)
api_schema_raw_sri = sri(api_schema) if api_schema else ""
idx_canon_sri = sri(canon(idx_raw))
api_schema_canon_sri = sri(canon(api_schema)) if api_schema else ""

print(json.dumps({
    "schema_id": "${SCHEMA_ID}",
    "idx_raw": idx_raw_sri,
    "api_raw_wrapper": api_raw_sri,
    "api_extracted_schema_raw": api_schema_raw_sri,
    "idx_canonicalized": idx_canon_sri,
    "api_extracted_schema_canonicalized": api_schema_canon_sri,
    "expected_digest_from_jsc": expected,
    "canonical_match": idx_canon_sri == expected,
    "raw_match": idx_raw_sri == expected,
}, indent=2))
PY

step_header "Step 6: Run verre trust resolution"
echo "Command used:"
print_cmd "node --input-type=module <resolveDID did=${AGENT_DID} skipDigestSRICheck=${SKIP_DIGEST_SRI}>"
(
  cd "$DIDCOMM_CLIENT_DIR"
  node --input-type=module - <<NODE
import { resolveDID } from '@verana-labs/verre'

const regs = [
  { id: 'vpr:verana:vna-testnet-1', baseUrls: ['https://idx.testnet.verana.network/verana'], production: true },
  { id: 'https://api.testnet.verana.network/verana', baseUrls: ['https://idx.testnet.verana.network/verana'], production: false },
]

const did = ${AGENT_DID@Q}
const result = await resolveDID(did, {
  verifiablePublicRegistries: regs,
  skipDigestSRICheck: ${SKIP_DIGEST_SRI},
})

console.log(JSON.stringify({
  did,
  verified: result.verified,
  outcome: result.outcome,
  metadata: result.metadata,
  service: result.service,
  serviceProvider: result.serviceProvider,
}, null, 2))
NODE
)

step_header "Step 7: Helpful follow-up checks"
echo "You can replay these commands manually:"
print_cmd "curl -sS ${SERVICE_VP_URL} | jq '{credential_id:.verifiableCredential[0].id, credential_schema_id:.verifiableCredential[0].credentialSchema.id, service_name:.verifiableCredential[0].credentialSubject.name}'"
print_cmd "curl -sS ${JSC_URL} | jq '{schema_ref:.credentialSubject.jsonSchema[\"\\\$ref\"], expected_digest:.credentialSubject.digestSRI}'"
print_cmd "curl -sS '${INDEX_BASE}/perm/v1/list?schema_id=${SCHEMA_ID}' | jq '.permissions[] | {id, type, did, perm_state, effective_from}'"

ok "Inspection complete"
