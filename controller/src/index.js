const crypto = require("crypto")
const express = require("express")
const { createMCPIRuntime } = require("@kya-os/mcp-i")

function asBool(value, fallback = false) {
  if (value === undefined) return fallback
  return ["1", "true", "yes", "on"].includes(String(value).toLowerCase())
}

function asInt(value, fallback) {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) ? parsed : fallback
}

const config = {
  port: asInt(process.env.PORT, 4101),
  agentName: process.env.AGENT_NAME || "MCPI VS Agent",
  vsAgentAdminUrl: process.env.VS_AGENT_ADMIN_URL || "http://127.0.0.1:3100",
  peerVsAgentAdminUrl: process.env.PEER_VS_AGENT_ADMIN_URL || "",
  peerVsAgentLabel: process.env.PEER_VS_AGENT_LABEL || "",
  peerMcpiUrl: process.env.PEER_MCPI_URL || "",
  ollamaBaseUrl: process.env.OLLAMA_BASE_URL || "http://127.0.0.1:11434",
  ollamaModel: process.env.OLLAMA_MODEL || "llama3.1:8b",
  mcpiIdentityPath: process.env.MCPI_IDENTITY_PATH || ".mcp-i",
  mcpiEnvironment: process.env.MCPI_ENV || "development",
  mcpiAuditEnabled: asBool(process.env.MCPI_AUDIT_ENABLED, true),
  publicBaseUrl: process.env.PUBLIC_BASE_URL || "",
}

const state = {
  runtime: null,
  wellKnownHandler: null,
  vsDid: null,
  welcomedConnections: new Set(),
  pendingPeerRequests: new Map(),
}

const app = express()
app.use(express.json({ limit: "2mb" }))

const INTERNAL_PEER_PREFIX = "[MCPI_INTERNAL]"
const PEER_PROTOCOL_VERSION = "mcpi-didcomm-v1"

function log(message, data) {
  const prefix = `[${config.agentName}]`
  if (data !== undefined) {
    console.log(prefix, message, data)
  } else {
    console.log(prefix, message)
  }
}

function getConnectionId(payload) {
  if (!payload || typeof payload !== "object") return null
  return (
    payload.connectionId ||
    payload?.message?.connectionId ||
    payload?.payload?.connectionId ||
    payload?.payload?.message?.connectionId ||
    null
  )
}

function getTextContent(payload) {
  if (!payload || typeof payload !== "object") return null
  const content = payload?.message?.content ?? payload?.payload?.message?.content ?? payload?.content
  return typeof content === "string" ? content : null
}

async function fetchVsDid() {
  try {
    const response = await fetch(`${config.vsAgentAdminUrl}/v1/agent`)
    if (!response.ok) {
      return
    }

    const body = await response.json()
    if (body && typeof body.publicDid === "string" && body.publicDid.length > 0) {
      state.vsDid = body.publicDid
    }
  } catch (_error) {
    // VS Agent might be starting up; keep previous value.
  }
}

async function fetchJson(url) {
  const response = await fetch(url)
  if (!response.ok) {
    const responseText = await response.text()
    throw new Error(`Request failed (${response.status}) for ${url}: ${responseText}`)
  }
  return await response.json()
}

function selectLatestConnection(records) {
  if (!Array.isArray(records) || records.length === 0) return null
  return records
    .slice()
    .sort((left, right) => {
      const leftTs = Date.parse(left?.updatedAt || left?.createdAt || 0)
      const rightTs = Date.parse(right?.updatedAt || right?.createdAt || 0)
      return leftTs - rightTs
    })
    .at(-1)
}

function sortConnectionsNewestFirst(records) {
  if (!Array.isArray(records)) return []
  return records
    .slice()
    .sort((left, right) => {
      const leftTs = Date.parse(left?.updatedAt || left?.createdAt || 0)
      const rightTs = Date.parse(right?.updatedAt || right?.createdAt || 0)
      return rightTs - leftTs
    })
}

async function getDirectPeerDidcommStatus() {
  if (!config.peerVsAgentAdminUrl) {
    return {
      configured: false,
      connected: false,
      reason: "PEER_VS_AGENT_ADMIN_URL is not configured",
    }
  }

  const [ownAgent, peerAgent, ownConnections, peerConnections] = await Promise.all([
    fetchJson(`${config.vsAgentAdminUrl}/v1/agent`),
    fetchJson(`${config.peerVsAgentAdminUrl}/v1/agent`),
    fetchJson(`${config.vsAgentAdminUrl}/v1/connections`),
    fetchJson(`${config.peerVsAgentAdminUrl}/v1/connections`),
  ])

  const ownVsDid = ownAgent?.publicDid || state.vsDid
  const peerVsDid = peerAgent?.publicDid || null
  const peerLabel = peerAgent?.label || config.peerVsAgentLabel || "peer"
  const ownLabel = ownAgent?.label || config.agentName

  const ownCandidates = sortConnectionsNewestFirst(
    (ownConnections || []).filter(
      connection =>
        connection?.state === "completed" &&
        (!connection?.theirLabel || connection.theirLabel === peerLabel),
    ),
  )

  const peerCandidates = sortConnectionsNewestFirst(
    (peerConnections || []).filter(
      connection =>
        connection?.state === "completed" &&
        (!connection?.theirLabel || connection.theirLabel === ownLabel),
    ),
  )

  let ownSide = null
  let peerSide = null
  for (const ownCandidate of ownCandidates) {
    const matchedPeer = peerCandidates.find(
      peerCandidate =>
        (ownCandidate?.theirDid && peerCandidate?.did && ownCandidate.theirDid === peerCandidate.did) ||
        (ownCandidate?.did && peerCandidate?.theirDid && ownCandidate.did === peerCandidate.theirDid) ||
        (ownCandidate?.invitationDid && peerVsDid && ownCandidate.invitationDid === peerVsDid) ||
        (peerCandidate?.invitationDid && ownVsDid && peerCandidate.invitationDid === ownVsDid),
    )
    if (matchedPeer) {
      ownSide = ownCandidate
      peerSide = matchedPeer
      break
    }
  }

  if (!ownSide || !peerSide) {
    return {
      configured: true,
      connected: false,
      ownVsDid,
      peerVsDid,
      peerLabel,
      reason: "No reciprocal completed DIDComm connection pair found",
    }
  }

  return {
    configured: true,
    connected: true,
    ownVsDid,
    peerVsDid,
    peerLabel,
    ownConnectionId: ownSide.id,
    peerConnectionId: peerSide.id,
    ownPeerDid: ownSide.theirDid,
    peerOwnDid: peerSide.did,
  }
}

async function sendVsTextMessage(connectionId, content) {
  const payload = {
    type: "text",
    connectionId,
    content,
  }

  const response = await fetch(`${config.vsAgentAdminUrl}/v1/message`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  })

  if (!response.ok) {
    const responseText = await response.text()
    throw new Error(`VS Agent message send failed (${response.status}): ${responseText}`)
  }
}

async function sendVsPeerEnvelope(connectionId, envelope) {
  const encoded = Buffer.from(JSON.stringify(envelope), "utf8").toString("base64url")
  await sendVsTextMessage(connectionId, `${INTERNAL_PEER_PREFIX}${encoded}`)
}

function parseVsPeerEnvelope(content) {
  if (typeof content !== "string" || !content.startsWith(INTERNAL_PEER_PREFIX)) {
    return null
  }

  try {
    const encoded = content.slice(INTERNAL_PEER_PREFIX.length)
    const parsed = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"))
    if (parsed?.protocol !== PEER_PROTOCOL_VERSION || typeof parsed?.kind !== "string") {
      return null
    }
    return parsed
  } catch (_error) {
    return null
  }
}

async function generateLocalAnswer(question, requester) {
  const requesterName = requester?.agentName || "another agent"
  const prompt = [
    `You are ${config.agentName}.`,
    `The requester is ${requesterName}.`,
    `Question: ${question}`,
    "Answer directly in at most 4 sentences.",
  ].join("\n")

  try {
    const response = await fetch(`${config.ollamaBaseUrl}/api/generate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: config.ollamaModel,
        prompt,
        stream: false,
        options: {
          temperature: 0.2,
        },
      }),
    })

    if (!response.ok) {
      throw new Error(`Ollama returned ${response.status}`)
    }

    const body = await response.json()
    if (typeof body?.response === "string" && body.response.trim().length > 0) {
      return body.response.trim()
    }

    throw new Error("Ollama response was empty")
  } catch (error) {
    log("Falling back to deterministic local response", error instanceof Error ? error.message : String(error))
    return `${config.agentName} fallback answer: I received \"${question}\" and could not reach Ollama.`
  }
}

function buildHandshakeRequest(ownIdentity, audience) {
  return {
    nonce: crypto.randomUUID(),
    audience,
    timestamp: Math.floor(Date.now() / 1000),
    clientDid: state.vsDid || ownIdentity.did,
    clientInfo: {
      name: config.agentName,
      version: "0.1.0",
      platform: "vs-agent-controller",
    },
  }
}

async function performLocalHandshake(handshakeRequest) {
  const handshake = await state.runtime.handleHandshake(handshakeRequest || {})
  if (!handshake?.sessionId) {
    throw new Error("Runtime handshake did not return sessionId")
  }
  return handshake
}

async function executeLocalMcpiQuery(sessionId, question, requester) {
  const session = state.runtime.getSession(sessionId)
  if (!session) {
    throw new Error(`session ${sessionId} not found`)
  }

  const nonce = await state.runtime.issueNonce(sessionId)
  const result = await state.runtime.processToolCall(
    "peer-answer",
    { question, requester },
    async (args) => {
      const answer = await generateLocalAnswer(args.question, args.requester)
      return {
        answer,
        question: args.question,
        responder: config.agentName,
        generatedAt: new Date().toISOString(),
      }
    },
    {
      ...session,
      nonce,
    },
  )

  const proof = state.runtime.getLastProof()
  const identity = await state.runtime.getIdentity()

  return {
    result,
    proof,
    responder: {
      agentName: config.agentName,
      mcpiDid: identity.did,
      vsDid: state.vsDid,
    },
  }
}

async function callPeerWithMcpiOverHttp(question) {
  if (!config.peerMcpiUrl) {
    throw new Error("PEER_MCPI_URL is not configured")
  }

  const ownIdentity = await state.runtime.getIdentity()

  let peerIdentity = null
  try {
    const identityResponse = await fetch(`${config.peerMcpiUrl}/mcpi/identity`)
    if (identityResponse.ok) {
      peerIdentity = await identityResponse.json()
    }
  } catch (_error) {
    // Not fatal: handshake can still work without explicit peer identity bootstrap.
  }

  const handshakeRequest = buildHandshakeRequest(
    ownIdentity,
    (() => {
      try {
        return new URL(config.peerMcpiUrl).host
      } catch (_error) {
        return config.peerMcpiUrl
      }
    })(),
  )
  if (peerIdentity?.mcpiDid) {
    handshakeRequest.agentDid = peerIdentity.mcpiDid
  }

  const handshakeResponse = await fetch(`${config.peerMcpiUrl}/mcpi/handshake`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(handshakeRequest),
  })

  if (!handshakeResponse.ok) {
    const responseText = await handshakeResponse.text()
    throw new Error(`Peer handshake failed (${handshakeResponse.status}): ${responseText}`)
  }

  const handshake = await handshakeResponse.json()
  if (!handshake?.sessionId) {
    throw new Error("Peer handshake did not return sessionId")
  }

  const peerQueryResponse = await fetch(`${config.peerMcpiUrl}/mcpi/query`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      sessionId: handshake.sessionId,
      question,
      requester: {
        agentName: config.agentName,
        mcpiDid: ownIdentity.did,
        vsDid: state.vsDid,
      },
    }),
  })

  if (!peerQueryResponse.ok) {
    const responseText = await peerQueryResponse.text()
    throw new Error(`Peer query failed (${peerQueryResponse.status}): ${responseText}`)
  }

  const payload = await peerQueryResponse.json()
  if (!payload?.result || !payload?.proof) {
    throw new Error("Peer query response did not include both result and proof")
  }

  let verified = false
  try {
    verified = await state.runtime.verifyProof(payload.result, payload.proof)
  } catch (_error) {
    verified = false
  }

  return {
    verified,
    handshake,
    payload,
    peerIdentity,
    transport: "http",
  }
}

function awaitPeerEnvelopeResponse(requestId, timeoutMs = 45000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      state.pendingPeerRequests.delete(requestId)
      reject(new Error(`Timed out waiting for peer DIDComm response for ${requestId}`))
    }, timeoutMs)
    timer.unref?.()

    state.pendingPeerRequests.set(requestId, {
      resolve,
      reject,
      timer,
    })
  })
}

function settlePeerEnvelopeResponse(requestId, result, error) {
  const pending = state.pendingPeerRequests.get(requestId)
  if (!pending) return false
  state.pendingPeerRequests.delete(requestId)
  clearTimeout(pending.timer)
  if (error) {
    pending.reject(error)
  } else {
    pending.resolve(result)
  }
  return true
}

async function callPeerWithMcpiOverDidcomm(question, peerStatus) {
  if (!peerStatus?.connected || !peerStatus?.ownConnectionId) {
    throw new Error("Direct peer DIDComm link is not connected")
  }

  const ownIdentity = await state.runtime.getIdentity()
  const requestId = crypto.randomUUID()
  const handshakeRequest = buildHandshakeRequest(ownIdentity, peerStatus.peerVsDid || peerStatus.peerLabel || "peer")

  const waitForResponse = awaitPeerEnvelopeResponse(requestId)
  try {
    await sendVsPeerEnvelope(peerStatus.ownConnectionId, {
      protocol: PEER_PROTOCOL_VERSION,
      kind: "query",
      requestId,
      question,
      requester: {
        agentName: config.agentName,
        mcpiDid: ownIdentity.did,
        vsDid: state.vsDid,
      },
      handshakeRequest,
      sentAt: new Date().toISOString(),
    })
  } catch (error) {
    settlePeerEnvelopeResponse(requestId, null, error instanceof Error ? error : new Error(String(error)))
    throw error
  }

  const responseEnvelope = await waitForResponse
  if (responseEnvelope?.kind === "error") {
    throw new Error(responseEnvelope.error || "Peer returned an unspecified DIDComm error")
  }
  if (responseEnvelope?.kind !== "response") {
    throw new Error(`Unexpected peer DIDComm envelope kind: ${responseEnvelope?.kind || "unknown"}`)
  }
  if (!responseEnvelope.payload?.result || !responseEnvelope.payload?.proof) {
    throw new Error("Peer DIDComm response did not include both result and proof")
  }

  let verified = false
  try {
    verified = await state.runtime.verifyProof(responseEnvelope.payload.result, responseEnvelope.payload.proof)
  } catch (_error) {
    verified = false
  }

  return {
    verified,
    handshake: responseEnvelope.handshake,
    payload: responseEnvelope.payload,
    peerIdentity: responseEnvelope.payload?.responder || null,
    transport: "didcomm",
  }
}

async function callPeerWithMcpi(question) {
  const peerStatus = await getDirectPeerDidcommStatus().catch(() => null)
  if (peerStatus?.connected) {
    return await callPeerWithMcpiOverDidcomm(question, peerStatus)
  }
  return await callPeerWithMcpiOverHttp(question)
}

async function handlePeerEnvelope(connectionId, envelope) {
  const peerStatus = await getDirectPeerDidcommStatus()
  if (!peerStatus?.connected || peerStatus.ownConnectionId !== connectionId) {
    log("Ignoring internal peer envelope from non-peer connection", { connectionId, kind: envelope?.kind })
    return
  }

  if (envelope.kind === "query") {
    try {
      const handshake = await performLocalHandshake(envelope.handshakeRequest || {})
      const payload = await executeLocalMcpiQuery(handshake.sessionId, String(envelope.question || ""), envelope.requester)
      await sendVsPeerEnvelope(connectionId, {
        protocol: PEER_PROTOCOL_VERSION,
        kind: "response",
        requestId: envelope.requestId,
        handshake,
        payload,
        sentAt: new Date().toISOString(),
      })
    } catch (error) {
      const messageText = error instanceof Error ? error.message : String(error)
      await sendVsPeerEnvelope(connectionId, {
        protocol: PEER_PROTOCOL_VERSION,
        kind: "error",
        requestId: envelope.requestId,
        error: messageText,
        sentAt: new Date().toISOString(),
      })
    }
    return
  }

  if (envelope.kind === "response" || envelope.kind === "error") {
    settlePeerEnvelopeResponse(
      envelope.requestId,
      envelope,
      envelope.kind === "error" ? new Error(envelope.error || "Peer DIDComm error") : null,
    )
    return
  }

  log("Ignoring unsupported internal peer envelope", { kind: envelope.kind })
}

async function handleIncomingMessage(webhookBody) {
  const connectionId = getConnectionId(webhookBody)
  const content = getTextContent(webhookBody)

  if (!connectionId || !content) {
    return
  }

  const message = content.trim()
  const peerEnvelope = parseVsPeerEnvelope(message)
  if (peerEnvelope) {
    await handlePeerEnvelope(connectionId, peerEnvelope)
    return
  }

  if (message.startsWith("/ask ")) {
    const question = message.slice(5).trim()
    if (!question) {
      await sendVsTextMessage(connectionId, "Usage: /ask <question>")
      return
    }

    try {
      const roundtrip = await callPeerWithMcpi(question)
      const resultText = typeof roundtrip.payload.result?.answer === "string"
        ? roundtrip.payload.result.answer
        : JSON.stringify(roundtrip.payload.result)

      const proofDid = roundtrip.payload.proof?.did || "unknown"
      const responderDid = roundtrip.payload.responder?.mcpiDid || roundtrip.peerIdentity?.mcpiDid || "unknown"
      const verificationText = roundtrip.verified ? "verified" : "NOT verified"

      const reply = [
        `MCPI roundtrip ${verificationText} via ${roundtrip.transport || "unknown"}.`,
        `Peer MCP-I DID: ${responderDid}`,
        `Proof DID: ${proofDid}`,
        `Answer: ${resultText}`,
      ].join("\n")

      await sendVsTextMessage(connectionId, reply)
      return
    } catch (error) {
      const messageText = error instanceof Error ? error.message : String(error)
      await sendVsTextMessage(connectionId, `MCPI roundtrip failed: ${messageText}`)
      return
    }
  }

  if (message === "/whoami") {
    const identity = await state.runtime.getIdentity()
    const reply = [
      `Agent: ${config.agentName}`,
      `MCP-I DID: ${identity.did}`,
      `VS DID: ${state.vsDid || "unknown (VS Agent may still be starting)"}`,
      `Peer URL: ${config.peerMcpiUrl || "not configured"}`,
    ].join("\n")
    await sendVsTextMessage(connectionId, reply)
    return
  }

  if (message === "/peerconn") {
    try {
      const status = await getDirectPeerDidcommStatus()
      const reply = status.connected
        ? [
            "Direct VS DIDComm link: connected",
            `Peer label: ${status.peerLabel}`,
            `Own VS DID: ${status.ownVsDid}`,
            `Peer VS DID: ${status.peerVsDid}`,
            `Own connection id: ${status.ownConnectionId}`,
            `Peer connection id: ${status.peerConnectionId}`,
          ].join("\n")
        : [
            "Direct VS DIDComm link: not connected",
            `Reason: ${status.reason || "unknown"}`,
            `Own VS DID: ${status.ownVsDid || state.vsDid || "unknown"}`,
            `Peer VS DID: ${status.peerVsDid || "unknown"}`,
          ].join("\n")
      await sendVsTextMessage(connectionId, reply)
      return
    } catch (error) {
      const messageText = error instanceof Error ? error.message : String(error)
      await sendVsTextMessage(connectionId, `Direct peer DIDComm check failed: ${messageText}`)
      return
    }
  }

  if (message === "/help") {
    await sendVsTextMessage(
      connectionId,
      [
        "Commands:",
        "/ask <question>  -> Ask the peer agent via MCP-I + proof verification",
        "/whoami          -> Show this agent identity",
        "/peerconn        -> Show direct VS-to-VS DIDComm link status",
        "/help            -> Show commands",
      ].join("\n"),
    )
    return
  }

  const localAnswer = await generateLocalAnswer(message, { agentName: "user" })
  await sendVsTextMessage(connectionId, localAnswer)
}

async function maybeSendWelcome(webhookBody, force = false) {
  const connectionId = getConnectionId(webhookBody)
  if (!connectionId) return

  try {
    const peerStatus = await getDirectPeerDidcommStatus()
    if (peerStatus?.connected && peerStatus.ownConnectionId === connectionId) {
      return
    }
  } catch (_error) {
    // Ignore transient peer status lookup failures during startup.
  }

  if (!force) {
    const stateValue = webhookBody?.state
    if (typeof stateValue === "string" && stateValue.toLowerCase() !== "completed") {
      return
    }
  }

  if (state.welcomedConnections.has(connectionId)) {
    return
  }

  state.welcomedConnections.add(connectionId)
  const welcome = [
    `Hi, I am ${config.agentName}.`,
    "Try:",
    "- /ask what is MCP-I?",
    "- /whoami",
    "- /peerconn",
    "- /help",
  ].join("\n")

  try {
    await sendVsTextMessage(connectionId, welcome)
  } catch (error) {
    log("Failed to send welcome message", error instanceof Error ? error.message : String(error))
  }
}

app.get("/health", (_req, res) => {
  res.json({
    status: "ok",
    agentName: config.agentName,
    vsDid: state.vsDid,
  })
})

app.get("/mcpi/identity", async (_req, res) => {
  const identity = await state.runtime.getIdentity()
  res.json({
    agentName: config.agentName,
    mcpiDid: identity.did,
    vsDid: state.vsDid,
    peerMcpiUrl: config.peerMcpiUrl,
  })
})

app.post("/mcpi/handshake", async (req, res) => {
  try {
    const response = await performLocalHandshake(req.body || {})
    res.json(response)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    res.status(500).json({ error: message })
  }
})

app.post("/mcpi/query", async (req, res) => {
  const sessionId = typeof req.body?.sessionId === "string" ? req.body.sessionId : ""
  const question = typeof req.body?.question === "string" ? req.body.question.trim() : ""
  const requester = req.body?.requester

  if (!sessionId || !question) {
    res.status(400).json({ error: "sessionId and question are required" })
    return
  }

  const session = state.runtime.getSession(sessionId)
  if (!session) {
    res.status(404).json({ error: `session ${sessionId} not found` })
    return
  }

  try {
    const payload = await executeLocalMcpiQuery(sessionId, question, requester)
    res.json(payload)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    res.status(500).json({ error: message })
  }
})

app.post("/mcpi/verify", async (req, res) => {
  try {
    const verified = await state.runtime.verifyProof(req.body?.result, req.body?.proof)
    res.json({ verified })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    res.status(500).json({ error: message })
  }
})

app.get(/^\/\.well-known\/.*/, async (req, res) => {
  const response = await state.wellKnownHandler(req.path)
  if (!response) {
    res.status(404).json({ error: "not found" })
    return
  }

  if (typeof response.status === "number") {
    Object.entries(response.headers || {}).forEach(([key, value]) => {
      res.setHeader(key, String(value))
    })

    if (typeof response.body === "string") {
      res.status(response.status).send(response.body)
      return
    }

    res.status(response.status).json(response.body)
    return
  }

  res.json(response)
})

app.post("/message-received", async (req, res) => {
  res.status(200).end()
  try {
    await handleIncomingMessage(req.body)
  } catch (error) {
    log("Message processing failed", error instanceof Error ? error.message : String(error))
  }
})

app.post("/connection-established", async (req, res) => {
  res.status(200).end()
  await maybeSendWelcome(req.body, true)
})

app.post("/connection-state-updated", async (req, res) => {
  res.status(200).end()
  await maybeSendWelcome(req.body, false)
})

async function bootstrap() {
  state.runtime = createMCPIRuntime({
    identity: {
      environment: config.mcpiEnvironment,
      devIdentityPath: config.mcpiIdentityPath,
    },
    audit: {
      enabled: config.mcpiAuditEnabled,
      includePayloads: false,
    },
    session: {
      timestampSkewSeconds: 120,
      sessionTtlMinutes: 30,
    },
  })

  await state.runtime.initialize()

  const serviceEndpoint = config.publicBaseUrl || `http://127.0.0.1:${config.port}`
  state.wellKnownHandler = state.runtime.createWellKnownHandler({
    serviceName: config.agentName,
    serviceEndpoint,
  })

  await fetchVsDid()
  setInterval(() => {
    fetchVsDid().catch(() => undefined)
  }, 30000).unref()

  app.listen(config.port, () => {
    log(`controller listening on http://127.0.0.1:${config.port}`)
    log(`peer URL: ${config.peerMcpiUrl || "<none>"}`)
    log(`VS Agent admin URL: ${config.vsAgentAdminUrl}`)
  })
}

bootstrap().catch((error) => {
  const message = error instanceof Error ? error.stack || error.message : String(error)
  console.error(message)
  process.exit(1)
})
