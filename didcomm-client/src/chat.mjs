// Import askar first due to wrapper initialization ordering.
import { askar, KdfMethod } from '@openwallet-foundation/askar-nodejs'
import { DidCommUserProfileModule, DidCommUserProfileModuleConfig } from '@2060.io/credo-ts-didcomm-user-profile'

import { createHash } from 'node:crypto'
import process from 'node:process'
import readline from 'node:readline/promises'
import { stdin as input, stdout as output } from 'node:process'

import { AskarModule } from '@credo-ts/askar'
import {
  Agent,
  ConsoleLogger,
  DidsModule,
  KeyDidRegistrar,
  KeyDidResolver,
  LogLevel,
  PeerDidRegistrar,
  PeerDidResolver,
  WebDidResolver,
  utils,
} from '@credo-ts/core'
import {
  DidCommApi,
  DidCommBasicMessageEventTypes,
  DidCommBasicMessageRole,
  DidCommHttpOutboundTransport,
  DidCommModule,
  DidCommWsOutboundTransport,
} from '@credo-ts/didcomm'
import { DidCommHttpInboundTransport, agentDependencies } from '@credo-ts/node'
import { WebVhDidResolver } from '@credo-ts/webvh'
import { resolveDID } from '@verana-labs/verre'

function parseArgs(argv) {
  const args = {
    invitationEndpoint: '',
    invitationUrl: '',
    network: 'testnet',
    message: '',
    waitMs: 30000,
    agentLabel: 'MCPI Terminal Client',
    allowUntrusted: false,
    legacy: false,
    walletSeed: '',
    listenPort: 4040,
    publicEndpoint: '',
  }

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    const next = argv[i + 1]
    switch (arg) {
      case '--invitation-endpoint':
        args.invitationEndpoint = next
        i += 1
        break
      case '--invitation-url':
        args.invitationUrl = next
        i += 1
        break
      case '--network':
        args.network = next
        i += 1
        break
      case '--message':
        args.message = next
        i += 1
        break
      case '--wait-ms':
        args.waitMs = Number(next)
        i += 1
        break
      case '--agent-label':
        args.agentLabel = next
        i += 1
        break
      case '--wallet-seed':
        args.walletSeed = next
        i += 1
        break
      case '--listen-port':
        args.listenPort = Number(next)
        i += 1
        break
      case '--public-endpoint':
        args.publicEndpoint = next
        i += 1
        break
      case '--allow-untrusted':
        args.allowUntrusted = true
        break
      case '--legacy':
        args.legacy = true
        break
      default:
        break
    }
  }

  if (!args.invitationEndpoint && !args.invitationUrl) {
    throw new Error('Provide --invitation-endpoint or --invitation-url')
  }

  return args
}

function getRegistryConfig(network) {
  if (network === 'devnet') {
    return [
      {
        id: 'vpr:verana:vna-devnet-1',
        baseUrls: ['https://idx.devnet.verana.network/verana'],
        production: false,
      },
      {
        id: 'https://api.devnet.verana.network/verana',
        baseUrls: ['https://idx.devnet.verana.network/verana'],
        production: false,
      },
    ]
  }

  return [
    {
      id: 'vpr:verana:vna-testnet-1',
      baseUrls: ['https://idx.testnet.verana.network/verana'],
      production: true,
    },
    {
      id: 'https://api.testnet.verana.network/verana',
      baseUrls: ['https://idx.testnet.verana.network/verana'],
      production: false,
    },
  ]
}

function decodeInvitation(invitationUrl) {
  const parsed = new URL(invitationUrl)
  const oob = parsed.searchParams.get('oob')
  if (!oob) {
    throw new Error(`Invitation URL is missing oob param: ${invitationUrl}`)
  }

  const invitation = JSON.parse(Buffer.from(oob, 'base64url').toString('utf8'))
  return { oob, invitation }
}

function didWebAlias(did) {
  if (!did.startsWith('did:webvh:')) return undefined
  const parts = did.split(':')
  return `did:web:${parts.slice(3).join(':')}`
}

async function fetchInvitationUrl(invitationEndpoint, legacy) {
  const endpoint = legacy ? `${invitationEndpoint}?legacy=true` : invitationEndpoint
  const response = await fetch(endpoint)
  if (!response.ok) {
    throw new Error(`Invitation endpoint returned HTTP ${response.status}`)
  }
  const payload = await response.json()
  if (!payload.url) {
    throw new Error(`Invitation endpoint did not return url: ${JSON.stringify(payload)}`)
  }
  return payload.url
}

async function verifyTrust(targetDid, network) {
  const registries = getRegistryConfig(network)
  const primary = await resolveDID(targetDid, { verifiablePublicRegistries: registries })
  const legacyDid = didWebAlias(targetDid)
  let alias = undefined
  if (legacyDid) {
    alias = await resolveDID(legacyDid, { verifiablePublicRegistries: registries })
  }
  return { primary, alias, legacyDid }
}

function walletId(label, seed) {
  if (seed) return `mcpi-${createHash('sha256').update(seed).digest('hex').slice(0, 16)}`
  return `mcpi-${createHash('sha256').update(label).digest('hex').slice(0, 16)}-${utils.uuid().slice(0, 6)}`
}

function printTrustResult(result, targetDid) {
  console.log('Trust check:')
  console.log(`  DID: ${targetDid}`)
  console.log(`  verified: ${String(result.primary.verified)}`)
  console.log(`  outcome: ${result.primary.outcome ?? 'n/a'}`)
  if (result.alias) {
    console.log(`  alias DID: ${result.legacyDid}`)
    console.log(`  alias verified: ${String(result.alias.verified)}`)
    console.log(`  alias outcome: ${result.alias.outcome ?? 'n/a'}`)
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const invitationUrl = args.invitationUrl || (await fetchInvitationUrl(args.invitationEndpoint, args.legacy))
  const { invitation } = decodeInvitation(invitationUrl)

  if (!Array.isArray(invitation.services) || invitation.services.length === 0 || typeof invitation.services[0] !== 'string') {
    throw new Error('Invitation does not contain a DID service reference')
  }

  const targetDid = invitation.services[0]
  const trust = await verifyTrust(targetDid, args.network)
  printTrustResult(trust, targetDid)

  if (!trust.primary.verified && !args.allowUntrusted) {
    throw new Error('Refusing DIDComm connection because the service DID is not trusted. Use --allow-untrusted to override.')
  }

  const agent = new Agent({
    config: {
      label: args.agentLabel,
      logger: new ConsoleLogger(LogLevel.warn),
    },
    dependencies: agentDependencies,
    modules: {
      askar: new AskarModule({
        askar,
        store: {
          id: walletId(args.agentLabel, args.walletSeed),
          key: 'DZ9hPqFWTPxemcGea72C1X1nusqk5wFNLq6QPjwXGqAa',
          keyDerivationMethod: KdfMethod.Raw,
        },
      }),
      dids: new DidsModule({
        resolvers: [new KeyDidResolver(), new PeerDidResolver(), new WebDidResolver(), new WebVhDidResolver()],
        registrars: [new KeyDidRegistrar(), new PeerDidRegistrar()],
      }),
      didcomm: new DidCommModule({
        transports: {
          inbound: args.publicEndpoint ? [new DidCommHttpInboundTransport({ port: args.listenPort })] : [],
          outbound: [new DidCommHttpOutboundTransport(), new DidCommWsOutboundTransport()],
        },
        endpoints: args.publicEndpoint ? [args.publicEndpoint] : ['didcomm:transport/queue'],
        connections: { autoAcceptConnections: true },
        credentials: false,
        proofs: false,
        mediator: false,
        mediationRecipient: false,
      }),
      userProfile: new DidCommUserProfileModule(new DidCommUserProfileModuleConfig({ autoSendProfile: true })),
    },
  })

  const seenInbound = new Set()
  agent.events.on(DidCommBasicMessageEventTypes.BasicMessageStateChanged, (event) => {
    const { basicMessageRecord, message } = event.payload
    if (basicMessageRecord.role !== 'receiver') return
    if (seenInbound.has(basicMessageRecord.id)) return
    seenInbound.add(basicMessageRecord.id)
    console.log(`\n[agent] ${message.content}`)
  })

  await agent.initialize()
  await agent.modules.userProfile.updateUserProfileData({
    displayName: args.agentLabel,
    description: 'Terminal DIDComm client for MCPI VS agents',
    preferredLanguage: 'en',
  })
  const didcomm = agent.dependencyManager.resolve(DidCommApi)
  if (args.publicEndpoint) {
    console.log(`Listening for inbound DIDComm on ${args.publicEndpoint} -> localhost:${args.listenPort}`)
  }
  console.log(`Connecting using invitation: ${invitationUrl}`)
  const { connectionRecord } = await didcomm.oob.receiveInvitationFromUrl(invitationUrl, {
    label: args.agentLabel,
    autoAcceptConnection: true,
  })
  if (!connectionRecord) {
    throw new Error('No connection record returned from invitation')
  }

  const useMessagePickup = !args.publicEndpoint
  const pickupTimer = useMessagePickup
    ? setInterval(async () => {
        try {
          await didcomm.messagePickup.pickupMessages({
            connectionId: connectionRecord.id,
            protocolVersion: 'v2',
            awaitCompletion: false,
          })
        } catch (_error) {
          // Ignore transient pickup failures while the connection is not ready yet.
        }
      }, 2000)
    : undefined

  const connected = await didcomm.connections.returnWhenIsConnected(connectionRecord.id, { timeoutMs: 60000 })
  console.log(`Connected to ${invitation.label} (${connected.id})`)
  const sessionStartedAt = Date.now()

  const printInboundMessages = async () => {
    const records = await didcomm.basicMessages.findAllByQuery({
      role: DidCommBasicMessageRole.Receiver,
    })
    records
      .sort((a, b) => new Date(a.sentTime).getTime() - new Date(b.sentTime).getTime())
      .forEach((record) => {
        if (seenInbound.has(record.id)) return
        if (new Date(record.sentTime).getTime() < sessionStartedAt - 5000) return
        seenInbound.add(record.id)
        console.log(`\n[agent] ${record.content}`)
      })
  }

  const inboundPollTimer = setInterval(() => {
    printInboundMessages().catch(() => {
      // Ignore transient polling failures during shutdown.
    })
  }, 1500)

  const sendMessage = async (text) => {
    const sent = await didcomm.basicMessages.sendMessage(connected.id, text)
    console.log(`[you] ${text} (${sent.id})`)
  }

  if (args.message) {
    await sendMessage(args.message)
    await new Promise((resolve) => setTimeout(resolve, args.waitMs))
    await printInboundMessages()
    clearInterval(inboundPollTimer)
    if (pickupTimer) clearInterval(pickupTimer)
    await agent.shutdown()
    return
  }

  const rl = readline.createInterface({ input, output, terminal: true })
  console.log('Type messages. Use /exit to quit.')
  while (true) {
    const line = (await rl.question('> ')).trim()
    if (!line) continue
    if (line === '/exit' || line === '/quit') break
    await sendMessage(line)
    await printInboundMessages()
  }

  rl.close()
  clearInterval(inboundPollTimer)
  if (pickupTimer) clearInterval(pickupTimer)
  await agent.shutdown()
}

main().catch(async (error) => {
  if (error instanceof Error) {
    console.error(error.stack ?? error.message)
    if ('cause' in error && error.cause) {
      console.error('CAUSE:', error.cause)
    }
  } else {
    console.error(error)
  }
  process.exitCode = 1
})
