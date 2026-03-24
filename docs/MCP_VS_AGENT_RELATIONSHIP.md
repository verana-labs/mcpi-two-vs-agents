# MCP, MCP Gateway, And VS Agent / Verana

This note documents the current understanding from the MCPI spike of how:

- MCP
- MCP gateways
- VS Agent
- Verana
- Hologram
- `verre`

relate to one another, and what the plausible integration patterns are.

## Short Answer

MCP and Verana are not competitors. They solve different layers of the problem.

- **MCP** is primarily an **application protocol** for exposing tools, resources, and prompts.
- **Verana / VS Agent** is primarily a **trust, identity, and secure-session layer**.

So the clean mental model is:

- **MCP answers:** "How do I call tools and access context?"
- **Verana answers:** "Who is this service or client, should I trust it, and how do we establish a secure interaction?"

## What MCP Is

At a high level, MCP uses the following shape:

```text
Host / AI app
-> MCP client
-> MCP server
-> tools / resources / prompts
```

MCP defines:

- a structured protocol for tool/resource/prompt exchange
- a client/server interaction model
- standard transports such as `stdio` and streamable HTTP

MCP does **not** by itself define a decentralized trust layer equivalent to:

- Verifiable Service identity
- DID-based recursive trust resolution
- ecosystem-governed issuer / verifier permissions
- DIDComm secure peer establishment

In normal MCP deployments, trust is usually based on:

- HTTPS
- OAuth / bearer tokens / API keys
- host-side approvals
- operator trust in the remote server

That is useful, but it is not the same thing as Verana trust resolution.

## What An MCP Gateway Usually Is

"MCP gateway" is usually an architectural pattern rather than a core MCP specification role.

In practice, an MCP gateway is often one of these:

1. a reverse proxy in front of one MCP server
2. an aggregator in front of many MCP servers
3. an auth/policy layer that sits in front of MCP servers
4. a bridge that exposes non-MCP systems as one MCP endpoint

A gateway typically does:

- routing
- auth termination
- policy enforcement
- normalization / aggregation
- logging / observability

So an MCP gateway is operational infrastructure around MCP, not the trust model itself.

## What VS Agent / Verana Adds

VS Agent + Verana gives a service:

- a **DID**
- public trust material linked from its DID document
- ECS-backed service identity
- recursive trust resolution through `verre` / resolver
- DIDComm secure peer sessions
- a path toward mutual verification of both service and user agent

That means Verana is closer to:

- service identity
- ecosystem trust
- mutual authentication
- authorization context
- secure session establishment

than to tool invocation.

## Where MCP Is In This Demo

The current MCPI demo does **not** expose a standard MCP server.

The current implementation is:

- VS Agent for DID / trust / DIDComm
- controller logic exposing custom `/mcpi/*` endpoints
- an MCP-I-flavored controller-to-controller or DIDComm-riding query layer

So the demo currently proves:

- Verana trust
- ECS-backed service identity
- user-to-agent DIDComm
- direct agent-to-agent DIDComm
- peer workload moving over the trusted A-to-B DIDComm link

It does **not** yet prove:

- a standard MCP server implementation
- a standard MCP gateway deployment
- a native "MCP extended by Verana" protocol

That distinction matters. The current spike is about the **trust and transport substrate**, not about a finished MCP server integration.

## How To Position MCP Against Verana

| Concern | MCP | Verana / VS Agent |
|---|---|---|
| Tool invocation | Yes | Not primary |
| Resources / prompts / tool schema exchange | Yes | No |
| Mutual service identity | Weak / external | Strong |
| Recursive trust resolution | No | Yes |
| Ecosystem permission governance | No | Yes |
| Secure peer session establishment | Transport-level only | DIDComm + trust |
| User/service reciprocal verification | Limited | Core design goal |

So the simplest way to say it is:

- **MCP is the data plane / capability plane**
- **Verana is the trust plane / session plane**

## Would Verana Replace An MCP Gateway?

Usually, no.

A gateway still has jobs such as:

- aggregating many MCP servers
- routing
- policy
- observability
- operational tenancy boundaries

Verana would more naturally sit:

- **in front of** a gateway
- **beside** a gateway
- or **around** the MCP service boundary

So the likely architecture is not:

```text
Verana replaces MCP gateway
```

but rather:

```text
VUA / VS
-> Verana trust resolution + secure session
-> MCP gateway / adapter
-> MCP server(s)
```

## Can Verana Wrap MCP Servers?

Yes. This is probably the most realistic integration model.

The pattern would be:

1. expose a service as a **Verifiable Service** through VS Agent
2. trust-resolve that service
3. establish a secure DIDComm or otherwise Verana-governed session
4. behind that trusted boundary, use one or more MCP servers for tools/resources/prompts

In that shape:

- the **front door** is Verana / VS Agent
- the **capability backend** can be MCP

That is a strong fit.

## Could Verana Hand A Token To An MCP Client?

Yes. That is another valid integration model.

Pattern:

1. client/VUA and service establish trust via Verana
2. service issues or brokers a scoped OAuth token / bearer token / session token
3. MCP client uses that token against a remote MCP server over HTTP

This is a compatibility-oriented model.

Advantages:

- easier to integrate with existing MCP clients
- can preserve current MCP auth expectations

Tradeoff:

- the strong mutual-trust story lives **above** the MCP session, not natively inside the MCP protocol

So this works, but it is not the cleanest "Verana-native" shape.

## Should MCP Be Treated As A VS Agent Transport?

High-level: probably no.

Reason:

- VS Agent already has a transport/session model centered on DIDComm
- MCP is an application protocol with its own transports and semantics

So MCP is better modeled as:

- **something that runs behind or above the VS Agent boundary**

rather than:

- **the transport layer of VS Agent**

The cleaner conceptual stack is:

```text
trust + identity + secure session
-> then capabilities / tools / resources
```

not:

```text
tool protocol as the base transport for trust
```

## Three Plausible Integration Patterns

### 1. VS Agent As Trusted Front Door, MCP Behind It

```text
VUA / client
-> trust resolve VS DID
-> DIDComm / trusted session
-> service adapter
-> MCP client
-> MCP server(s)
```

This is the cleanest separation of concerns.

Use this when:

- Verana trust is mandatory
- existing MCP backends should remain usable
- you want the service identity to be a Verifiable Service

### 2. Verana-Authenticated Session, Then Tokenized MCP Access

```text
VUA / client
-> Verana trust resolution
-> service authenticates VUA
-> service issues scoped token
-> MCP client uses token against MCP server
```

Use this when:

- you want easier compatibility with existing MCP HTTP deployments
- you are willing to keep MCP auth token-based

### 3. MCP Messages Carried Inside A DIDComm / VS Session

```text
Agent A
-> trust resolve Agent B
-> direct DIDComm session
-> MCP-shaped messages carried over that session
-> Agent B executes tools/resources
```

This is conceptually attractive, but it is not the current standard MCP shape and would likely be a custom integration or adaptation.

Use this only if:

- you explicitly want a Verana-native secure peer channel to be the primary transport
- you accept some custom adapter work

## What This Means For The MCPI Spike

The current spike should be read as proving:

1. Verana / VS Agent can provide the trust and DIDComm substrate for agents
2. peer workload can be moved onto that trusted channel
3. application protocols can ride above that substrate

The spike should **not** currently be read as proving:

1. MCP server compatibility out of the box
2. a formal MCP gateway replacement
3. a finished "MCP over Verana" standard

## Recommended High-Level Direction

If the goal is to connect multiple agents securely while still benefiting from MCP, the most defensible path is:

1. keep **Verana / VS Agent** as the trust and session layer
2. treat **MCP** as the capability layer
3. build an adapter where a trusted Verifiable Service exposes or consumes MCP functionality behind that boundary

That gives:

- trust-resolved service identity
- optional mutual service / client verification
- secure peer sessions
- tool interoperability

without forcing MCP to solve a trust problem it was not originally designed to solve.

## Bottom Line

The cleanest positioning is:

- **MCP:** "what can this service do?"
- **Verana / VS Agent:** "who is this service, who is the caller, and should this interaction be trusted?"

So the likely future is not Verana replacing MCP.

It is:

- **Verana wrapping or fronting MCP-enabled services**
- or **Verana brokering trusted access to MCP capabilities**

That is the most coherent interpretation of how the two concepts fit together.
