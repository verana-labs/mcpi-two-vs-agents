# MCPI Two VS Agents Demo

This demo creates **two VS agents** (Agent A and Agent B), gives each one a **testnet trust stack** (Organization credential, Service credential, Trust Registry), and proves an **MCP-I roundtrip** where one agent queries the other and verifies identity proof.

For a fuller explanation of what the current demo proves, what it does **not** prove, and the target paper-aligned architecture, read:

- [docs/ARCHITECTURE.md](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/docs/ARCHITECTURE.md)

## Phase 3 status

Phase 3 Step 1 and Step 2 are now implemented:

- Agent A and Agent B have a **real direct VS-to-VS DIDComm connection** in k8s.
- Agent A can report that link in chat with `/peerconn`.
- The link is created headlessly with [`scripts/link-vs-agents.sh`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/scripts/link-vs-agents.sh).
- `/ask ...` now rides that direct A-to-B DIDComm channel instead of controller-to-controller HTTP.

What this proves:

- the two deployed VS Agents can be linked directly to each other
- the demo no longer depends only on user-to-agent DIDComm
- we can inspect the live A-to-B DIDComm connection from inside Agent A
- the peer query/response now runs over the A-to-B DIDComm link

What this does **not** prove yet:

- public trust verification for the service DID is still failing in the terminal client
- MCP-I proof verification is still returning `NOT verified`
- no credential-gated authorization is happening inside the A-to-B DIDComm session yet

## Why this shape

The VS Agent API supports message exchange and invitation creation, but there is no direct admin endpoint for importing another agent's invitation URL and auto-linking two VS agents headless.

So this demo keeps VS Agent as the trust and DIDComm anchor, and implements MCP-I agent-to-agent calls in the controller layer:

1. User talks to Agent A through VS Agent webhook.
2. Controller A sends a structured peer request over Agent A's direct DIDComm connection to Agent B.
3. Agent B forwards that DIDComm message into Controller B.
4. Controller B returns result + proof back over the same DIDComm channel.
5. Controller A verifies proof and returns status to the user.

## What was taken from `verana-demos`

The onboarding scripts here wrap `verana-demos/scripts/vs-demo` directly, preserving:

- Dynamic ECS schema discovery from ECS DID document.
- Credential cleanup + relink behavior.
- Testnet/devnet network switch behavior.
- Root/issuer permission flows with effective time wait.
- Duplicate trust-registry schema detection.
- Optional AnonCreds switch.

## Layout

```text
mcpi-two-vs-agents/
├── controller/                  # Single controller app, run twice
│   └── src/index.js
├── didcomm-client/              # Credo-based terminal DIDComm client
│   └── src/chat.mjs
├── k8s/
│   └── controllers/
├── profiles/
│   ├── agent-a/
│   │   ├── config.env
│   │   ├── schema.json
│   │   └── deployment.yaml
│   └── agent-b/
│       ├── config.env
│       ├── schema.json
│       └── deployment.yaml
└── scripts/
    ├── bootstrap-ecs-trust.sh
    ├── didcomm-chat.sh
    ├── inspect-vs-trust.sh
    ├── onboard-agent.sh
    ├── step-01-deploy.sh
    ├── step-02-ecs.sh
    ├── step-03-trust-registry.sh
    ├── start-controller.sh
    └── start-both-controllers.sh
```

## Prerequisites

- `veranad`, `jq`, `curl`
- Docker + ngrok (for local VS agent deploy from step 01)
- Funded testnet accounts in local `veranad` keyring for:
  - `mcpi-agent-a-admin`
  - `mcpi-agent-b-admin`
- Node.js 18+
- Optional: local Ollama (`http://127.0.0.1:11434`)

## Quick start

From this directory:

```bash
cd /Users/mathieu/datashare/2060io/2060-demos/mcpi-two-vs-agents

# 1) Install controller deps
cd controller
npm install
cd ..

# 2) Full trust stack for Agent A and Agent B (testnet)
./scripts/onboard-agent.sh agent-a
./scripts/onboard-agent.sh agent-b

# 3) Start both controllers
./scripts/start-both-controllers.sh
```

## K8s mode

All onboarding scripts support `DEPLOY_MODE=k8s`.

Step 1 only (deploy VS agent through Helm):

```bash
cd /Users/mathieu/datashare/2060io/2060-demos/mcpi-two-vs-agents
DEPLOY_MODE=k8s ./scripts/step-01-deploy.sh agent-a
DEPLOY_MODE=k8s ./scripts/step-01-deploy.sh agent-b
```

Full onboarding in k8s mode:

```bash
DEPLOY_MODE=k8s ./scripts/onboard-agent.sh agent-a
DEPLOY_MODE=k8s ./scripts/onboard-agent.sh agent-b
```

To rerun just the ECS onboarding flow for an already deployed agent:

```bash
DEPLOY_MODE=k8s ./scripts/bootstrap-ecs-trust.sh agent-a
DEPLOY_MODE=k8s ./scripts/bootstrap-ecs-trust.sh agent-b
```

If you need the old localhost admin bridge as a fallback, stop a profile's port-forward:

```bash
./scripts/stop-k8s-port-forward.sh agent-a
./scripts/stop-k8s-port-forward.sh agent-b
```

If you want step-by-step trust setup instead of all-in-one:

```bash
./scripts/step-01-deploy.sh agent-a
./scripts/step-02-ecs.sh agent-a
./scripts/step-03-trust-registry.sh agent-a
```

Repeat for `agent-b`.

For k8s mode, start controllers like this so they target the admin ingress instead of a local `kubectl port-forward`:

```bash
DEPLOY_MODE=k8s ./scripts/start-both-controllers.sh
```

To run controllers in Kubernetes instead of on your laptop:

```bash
OLLAMA_BASE_URL=https://your-current-ollama-tunnel.lhr.life ./scripts/deploy-k8s-controllers.sh
```

If your `localhost.run` Ollama URL rotates later, update the in-cluster controllers with one command:

```bash
./scripts/update-k8s-controller-ollama-url.sh https://your-new-ollama-tunnel.lhr.life
```

That creates:

- Internal A: `http://mcpi-controller-a.vna-testnet-1.svc.cluster.local:4101`
- Internal B: `http://mcpi-controller-b.vna-testnet-1.svc.cluster.local:4102`
- External A: `https://mcpi-controller-a.testnet.verana.network`
- External B: `https://mcpi-controller-b.testnet.verana.network`

## Direct VS-to-VS DIDComm link

To establish or re-check the direct A-to-B DIDComm link:

```bash
cd /Users/mathieu/datashare/2060io/mcpi-two-vs-agents
DEPLOY_MODE=k8s ./scripts/link-vs-agents.sh agent-a agent-b
```

What that script does:

1. fetches Agent A's public invitation from its admin API
2. runs a one-off bootstrap helper inside the Agent B pod
3. consumes Agent A's invitation using the same wallet/storage as the running Agent B VS Agent
4. waits until both admin APIs show reciprocal completed connection records
5. writes the result to:
   - `.state/links/agent-a__agent-b.json`

The current live direct link is exposed through `/peerconn` and should report:

- Agent A own connection id: `547475e5-02b0-46f9-9a93-5873d55ed56a`
- Agent B peer connection id: `9e067f9a-ba48-4538-b29c-0c15be6534fc`

With that link in place, `/ask ...` now returns:

- `MCPI roundtrip ... via didcomm.`

## Terminal DIDComm chat

The repo includes a Credo-based terminal client that:

- attempts to verify the agent trust chain with `verre`
- connects using a VS Agent invitation
- exchanges DIDComm messages in a terminal session

For the current interop, use a **public callback URL** for the terminal client. Queue-only mode does not complete DIDExchange reliably against the current deployment.

```bash
cd /Users/mathieu/datashare/2060io/mcpi-two-vs-agents

# 1) Create a public endpoint for the local DIDComm client
ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -R 80:localhost:4040 nokey@localhost.run

# 2) In another terminal, connect to Agent A
CLIENT_PUBLIC_ENDPOINT=https://<current-lhr-life-url> \
CLIENT_LISTEN_PORT=4040 \
DEPLOY_MODE=k8s \
./scripts/didcomm-chat.sh agent-a --allow-untrusted
```

One-shot examples:

```bash
CLIENT_PUBLIC_ENDPOINT=https://<current-lhr-life-url> CLIENT_LISTEN_PORT=4040 DEPLOY_MODE=k8s \
./scripts/didcomm-chat.sh agent-a --allow-untrusted --message '/peerconn'

CLIENT_PUBLIC_ENDPOINT=https://<current-lhr-life-url> CLIENT_LISTEN_PORT=4040 DEPLOY_MODE=k8s \
./scripts/didcomm-chat.sh agent-a --allow-untrusted --message '/whoami'

CLIENT_PUBLIC_ENDPOINT=https://<current-lhr-life-url> CLIENT_LISTEN_PORT=4040 DEPLOY_MODE=k8s \
./scripts/didcomm-chat.sh agent-a --allow-untrusted --message '/ask what is mcp-i?'
```

Trust inspection helper:

```bash
./scripts/inspect-vs-trust.sh https://mcpi-agent-a.testnet.verana.network
./scripts/inspect-vs-trust.sh https://mcpi-agent-a.testnet.verana.network --skip-digest-sri
```

What it shows:

- the DID Document and linked VP endpoints
- the service VP and referenced `JsonSchemaCredential`
- raw vs canonicalized schema digests from `idx` and `api`
- the final `verre` resolution result, with or without `skipDigestSRICheck`
- exact `curl`/`jq` commands you can replay manually

Known limitation:

- strict trust validation depends on the current ECS onboarding state of the specific VS agent
- after re-running `DEPLOY_MODE=k8s ./scripts/step-02-ecs.sh <agent-name>`, strict `verre` validation should pass for that agent
- Hologram currently resolves trust with `skipDigestSRICheck` enabled, so its behavior may differ from strict terminal validation when testnet schema-processing issues resurface

## Demo commands in chat

Once a user is connected to an agent:

- `/help`
- `/whoami`
- `/peerconn`
- `/ask what is MCP-I?`

`/ask ...` executes the MCP-I roundtrip to the peer agent over the direct A-to-B DIDComm link and returns verification status.

`/peerconn` reports whether Agent A can see the direct VS-to-VS DIDComm link to Agent B.

## Useful endpoints

Agent A controller defaults:

- `GET http://127.0.0.1:4101/health`
- `GET http://127.0.0.1:4101/mcpi/identity`
- `POST http://127.0.0.1:4101/mcpi/handshake`
- `POST http://127.0.0.1:4101/mcpi/query`

Agent B controller defaults:

- `GET http://127.0.0.1:4102/health`
- `GET http://127.0.0.1:4102/mcpi/identity`
- `POST http://127.0.0.1:4102/mcpi/handshake`
- `POST http://127.0.0.1:4102/mcpi/query`

## Current boundaries

- MCP-I proof verification is implemented over controller-to-controller HTTP calls.
- VS Agent trust stack is fully testnet-aligned via existing Verana scripts.
- DIDComm-native MCP-I routing between two VS agents can be a next phase once direct OOB intake or connector logic is available.
