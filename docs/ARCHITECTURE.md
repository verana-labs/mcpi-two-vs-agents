# MCPI Demo Architecture

**Status**: working integration prototype  
**Last updated**: March 19, 2026

## Purpose

This document makes three things explicit:

1. what the current demo actually is
2. what a paper-aligned / target architecture would be
3. what has to change to move from the current demo to that target

It is written to prevent over-claiming. The current demo is useful, but it does not yet prove the full end-state.

## Short Answer

- The current demo proves that **Verana + VS Agent can provide a trust anchor and DIDComm edge for AI agents**.
- It also proves that a separate **MCP-I-flavored controller protocol** can be layered on top of that trust anchor.
- It does **not** yet prove that MCP-I is implemented as a clean extension of standard MCP.
- It does **not** yet prove full **DIDComm-native, proof-verifiable, agent-to-agent** interaction in the sense described by the Verana trust whitepaper.

## Current Demo

### Current shape

```text
Hologram or terminal DIDComm client
-> Agent A VS Agent
-> Controller A
-> Agent A sends peer request over direct DIDComm to Agent B
-> Agent B VS Agent
-> Controller B
-> Ollama
-> Controller B returns result + proof over DIDComm
-> Controller A verifies and formats response
-> Agent A VS Agent
-> user client
```

### What is actually implemented

The controller uses the MCP-I runtime:

- [`controller/src/index.js:3`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:3)
- [`controller/src/index.js:468`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:468)

And exposes custom HTTP endpoints:

- [`controller/src/index.js:340`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:340) `GET /mcpi/identity`
- [`controller/src/index.js:350`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:350) `POST /mcpi/handshake`
- [`controller/src/index.js:360`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:360) `POST /mcpi/query`
- [`controller/src/index.js:414`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:414) `POST /mcpi/verify`

Agent A performs the peer call in:

- [`controller/src/index.js:138`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:138)

The DIDComm-facing user path is separate:

- webhook receive: [`controller/src/index.js:448`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:448)
- VS Agent reply send: [`controller/src/index.js:80`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:80)

### What the current demo proves

1. VS Agents can be deployed as Verifiable Services with ECS-backed trust onboarding.
2. Hologram and a terminal Credo client can talk to Agent A over DIDComm.
3. Agent A can hand a request to Controller A.
4. Agent A and Agent B hold a real reciprocal VS-to-VS DIDComm connection.
5. Controller A can send a structured peer query over that DIDComm link.
6. Controller B can return answer plus proof material over the same DIDComm link.
7. Agent A can deliver the final response back to the DIDComm client.

### What the current demo does not prove

1. That MCP-I is running as a standard MCP server extension.
2. That agent-to-agent trust negotiation is happening over DIDComm.
3. That proof verification is currently sound.
4. That the MCP-I signer identity is cleanly bound to the Verana / VS identity.

## Why This Matters

The current demo is best understood as:

- **Verana / VS Agent** for trust, DID, and DIDComm
- **controller** for MCP-I runtime and app logic

So the current architecture is:

- trust and transport at the edge
- MCP-I-like query/proof logic in a sidecar/controller layer

That is a valid integration spike. It is not yet a fully unified agent-to-agent trust protocol.

## Interpretation Of MCP-I

Based on the current repo, the most defensible interpretation is:

- **conceptually**, MCP-I looks like an attempt to add identity, attestation, and proof semantics to MCP-style agent interactions
- **operationally in this repo**, MCP-I behaves as its own controller-side protocol surface

So today we should say:

- **connected to MCP as an ambition**
- **implemented separately in this demo**

We should not claim that the current demo proves a protocol-native MCP extension.

## Paper-Aligned Target Architecture

The reference whitepaper is:

- [`gov-ai-agents-with-verifiable-trust-1.2.pdf`](/Users/mathieu/Matlux%20Dropbox/Matlux%20Ltd/projects/2026.io/sub-projects/ai-trust-network/gov-ai-agents-with-verifiable-trust-1.2.pdf)

The paper's key claims relevant here are:

1. an AI agent is a **Verifiable Service**
2. peers should perform **trust resolution before connection**
3. once trust is established, peers should use **DIDComm** as the secure channel
4. richer authorization and credential exchange can happen **inside DIDComm**
5. the whole system should support **auditability, authorization, and cross-organizational coordination**

The paper-aligned architecture therefore looks like this:

```text
Agent A resolves Agent B DID
-> validates linked credentials and trust chain
-> Agent B resolves Agent A DID and does the same
-> both establish DIDComm directly
-> additional credential requests/presentations happen inside DIDComm if needed
-> task/query protocol runs over or is bootstrapped from that trusted DIDComm session
-> proofs / audit trail are tied back to the same trust identity
```

### What "paper-aligned" means concretely

1. **Pre-connection trust verification**
   - not "connect first, trust later"
2. **Mutual DIDComm channel between the two agents**
   - not just client-to-agent DIDComm
3. **Credential-gated authorization when required**
   - request/present inside DIDComm
4. **Identity coherence**
   - signer identity and service identity must be linked
5. **Auditable decision trail**
   - enough data to reconstruct who was trusted, under what governance, and when

## Gap Analysis

### Gap 1: credential-gated agent-to-agent authorization is still missing inside DIDComm

Current:

- peer query payload now rides over the direct A-to-B DIDComm link
- but Agent B does not yet request/present any authorization credential before answering

Target:

- Agent B can challenge Agent A for a credential inside the DIDComm session
- Agent A can present it and Agent B can authorize based on that result

### Gap 2: proof verification is not trustworthy yet

Current:

- `verifyProof()` returns `false` in the current demo because of defects in the MCP-I package path

Target:

- proof verification must honestly return `true` when a valid exchange occurred

### Gap 3: MCP-I identity is not yet bound to Verana identity

Current:

- VS DID and MCP-I DID are parallel identities

Target:

- the proof signer must be bound to the Verana/VS identity in a defensible way

### Gap 4: no DIDComm-native credential request/authorization step between the two agents

Current:

- trust onboarding exists
- but live peer authorization inside DIDComm is not part of the roundtrip

Target:

- if Agent B requires a capability or access credential from Agent A, it should request it in the DIDComm session

### Gap 5: MCP relationship is still ambiguous

Current:

- MCP-I is used in a custom controller protocol

Target:

- either:
  - clearly formalize MCP-I as a separate protocol, or
  - implement it as a recognizable extension of standard MCP interaction

## Value Of The Current Demo

The current demo has real value, but the value is specific:

1. It proves the **Verana trust anchor** part.
2. It proves the **VS Agent DIDComm edge** part.
3. It proves there is room to attach an **identity-aware controller protocol** to that edge.
4. It gives us a real debugging surface through:
   - Hologram
   - terminal Credo client
   - ECS onboarding automation
5. It surfaces the exact technical gaps rather than hiding them.

This is a good Phase 1.

It is not a finished claim.

## Phase 3 Plan

The next meaningful phase is to move toward a paper-aligned and strategically credible story.

### Phase 3 objective

Make it defensible to say:

> Verana provides the trust and DIDComm layer for secure agent-to-agent interaction, and MCP-I or a task protocol can run on top of that trusted channel.

### Phase 3 minimum scope

#### 1. Direct agent-to-agent DIDComm connection

Goal:

- Agent A and Agent B can establish a DIDComm connection directly, not only user-to-agent

What likely has to change:

- either improve VS Agent admin/connector flow to support headless peer linking
- or build a small bridge/helper that imports invitations and completes the DIDComm connection between the agents

Success condition:

- Agent A and Agent B have a real DIDComm connection record between them

**Current implementation status**

This step is now implemented in the spike environment:

- Agent A and Agent B have a reciprocal completed VS-to-VS DIDComm connection in k8s
- the link is created headlessly with [`scripts/link-vs-agents.sh`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/scripts/link-vs-agents.sh)
- Agent A exposes the status through the chat command:
  - [`controller/src/index.js:383`](/Users/mathieu/datashare/2060io/mcpi-two-vs-agents/controller/src/index.js:383) `/peerconn`

The current live link reports:

- Agent A own-side connection id: `547475e5-02b0-46f9-9a93-5873d55ed56a`
- Agent B peer-side connection id: `9e067f9a-ba48-4538-b29c-0c15be6534fc`

What is still missing:

- no credential-gated authorization is happening inside the A-to-B DIDComm session yet
- proof verification and trust resolution still have separate open defects

#### 2. Route peer queries over the trusted DIDComm channel

Goal:

- the peer query is no longer raw controller-to-controller HTTP as the primary trust-bearing hop

Possible shapes:

- DIDComm basic message carrying the query payload
- DIDComm attachment carrying structured request/response payloads
- DIDComm bootstrap for a secondary task channel with explicit identity binding

Success condition:

- the roundtrip between A and B is visibly anchored in the DIDComm session

**Current implementation status**

This step is now implemented in the spike environment:

- `/ask ...` now sends a structured controller payload over the direct A-to-B DIDComm link
- Controller B processes the peer query locally and sends result + proof back over DIDComm
- Agent A's user-facing reply now reports:
  - `MCPI roundtrip ... via didcomm.`

What is still missing:

- the DIDComm payload is a controller-defined internal envelope, not a standardized MCP or MCP-I transport
- there is still no credential request/presentation step inside that peer exchange

#### 3. Add credential-gated authorization for at least one peer action

Goal:

- demonstrate the paper's "request credential, verify, then proceed" pattern

Minimal example:

- Agent B requires Agent A to present a credential before answering `/ask`

Success condition:

- denial without required credential
- success when required credential is presented and verified

#### 4. Bind proof signer identity to the VS / Verana identity

Goal:

- stop having an unbound parallel identity story

Possible approaches:

- derive the MCP-I signer from the VS-controlled key material if feasible
- or issue an explicit credential linking the MCP-I signer DID to the VS service DID

Success condition:

- we can explain, without hand-waving, why a proof signed by X should be trusted as coming from Verifiable Service Y

#### 5. Fix or replace the current proof verifier

Goal:

- `verified=true` must mean something real

Success condition:

- successful roundtrip yields valid proof verification
- broken or tampered payload yields verification failure

## Recommended Order

If we execute Phase 3, the order should be:

1. direct A-to-B DIDComm connection
2. route the peer exchange through DIDComm
3. add credential-gated authorization inside that flow
4. bind signer identity to VS identity
5. fix proof verification and tighten audit semantics

That order is important because:

- there is no point polishing proof semantics if the exchange is still outside the trusted peer channel
- there is no point claiming secure agent-to-agent communication before the two agents actually talk through DIDComm

## Claims We Can Make Now

We can honestly say:

- Verana can provide a trust stack and DIDComm edge for AI agents.
- VS Agent can expose those agents to Hologram and Credo-based DIDComm clients.
- An MCP-I-flavored protocol can be layered on top of that trust anchor.

We should not yet say:

- MCP-I has been demonstrated as a clean extension of standard MCP.
- Verana + VS Agent already solve the full secure agent-to-agent communication problem.
- the current proof verification path is production-trustworthy.

## Current Operational Truth

Phase 3 Step 1 and Step 2 are now in this intermediate state:

```text
User client
-> Agent A over DIDComm

Agent A
-> has a direct DIDComm connection to Agent B
-> can report that connection with /peerconn
-> uses that same DIDComm link for /ask

Controller B still performs the MCP-I runtime work locally
and proof verification still happens in controller A
```

So the demo now proves:

- direct agent-to-agent DIDComm connectivity exists
- the peer workload can ride that channel

It still does not prove:

- credential-gated authorization inside the DIDComm peer session
- clean standard MCP transport semantics

There is also a separate unresolved trust issue on the public service DID:

- the public invitation uses `did:webvh`
- terminal-client trust resolution currently returns `invalid`
- the deployment is not serving the `did:webvh` material expected by the resolver, including `did.jsonl`

That issue affects the ability to claim externally verified service trust from the terminal client.
It does **not** invalidate the fact that the live VS Agents now hold a direct completed DIDComm connection to each other inside the cluster.

## Decision Rule For Future Work

Future changes should be judged against one question:

> Does this make the demo more paper-aligned and more honest, or just more impressive-looking?

If it is only more impressive-looking, it is the wrong next step.
