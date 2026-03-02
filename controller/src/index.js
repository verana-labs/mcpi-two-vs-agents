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
}

const app = express()
app.use(express.json({ limit: "2mb" }))

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

async function callPeerWithMcpi(question) {
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

  const handshakeRequest = {
    nonce: crypto.randomUUID(),
    audience: (() => {
      try {
        return new URL(config.peerMcpiUrl).host
      } catch (_error) {
        return config.peerMcpiUrl
      }
    })(),
    timestamp: Math.floor(Date.now() / 1000),
    clientDid: state.vsDid || ownIdentity.did,
    agentDid: peerIdentity?.mcpiDid,
    clientInfo: {
      name: config.agentName,
      version: "0.1.0",
      platform: "vs-agent-controller",
    },
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
  }
}

async function handleIncomingMessage(webhookBody) {
  const connectionId = getConnectionId(webhookBody)
  const content = getTextContent(webhookBody)

  if (!connectionId || !content) {
    return
  }

  const message = content.trim()

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
        `MCPI roundtrip ${verificationText}.`,
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

  if (message === "/help") {
    await sendVsTextMessage(
      connectionId,
      [
        "Commands:",
        "/ask <question>  -> Ask the peer agent via MCP-I + proof verification",
        "/whoami          -> Show this agent identity",
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
    const response = await state.runtime.handleHandshake(req.body || {})
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

    res.json({
      result,
      proof,
      responder: {
        agentName: config.agentName,
        mcpiDid: identity.did,
        vsDid: state.vsDid,
      },
    })
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
