const { setupAgent } = require('/www/apps/vs-agent/build/src/utils/setupAgent.js')
const { parseDid, LogLevel } = require('@credo-ts/core')
const { KdfMethod } = require('@openwallet-foundation/askar-nodejs')

async function main() {
  const sourceInvitationUrl = process.env.SOURCE_INVITATION_URL
  if (!sourceInvitationUrl) {
    throw new Error('SOURCE_INVITATION_URL is required')
  }

  const publicDid = process.env.AGENT_PUBLIC_DID
  if (!publicDid) {
    throw new Error('AGENT_PUBLIC_DID is required in target pod')
  }

  const parsedDid = parseDid(publicDid)
  const domain = parsedDid.id.includes(':') ? parsedDid.id.split(':')[1] : parsedDid.id
  const endpoints = process.env.AGENT_ENDPOINTS
    ? process.env.AGENT_ENDPOINTS.split(',').map(item => item.trim()).filter(Boolean)
    : [`wss://${domain}`]
  const publicApiBaseUrl = process.env.PUBLIC_API_BASE_URL || `https://${domain}`

  const { agent } = await setupAgent({
    endpoints,
    port: 3001,
    walletConfig: {
      id: process.env.AGENT_WALLET_ID || 'test-vs-agent',
      key: process.env.AGENT_WALLET_KEY || 'test-vs-agent',
      keyDerivationMethod: process.env.AGENT_WALLET_KEY_DERIVATION_METHOD || KdfMethod.Argon2IMod,
      database: undefined,
    },
    label: process.env.AGENT_LABEL || 'MCPI VS Agent',
    displayPictureUrl: process.env.AGENT_INVITATION_IMAGE_URL,
    parsedDid,
    logLevel: LogLevel.error,
    publicApiBaseUrl,
    autoDiscloseUserProfile: true,
    autoUpdateStorageOnStartup: false,
  })

  try {
    const { connectionRecord } = await agent.didcomm.oob.receiveInvitationFromUrl(sourceInvitationUrl, {
      label: process.env.AGENT_LABEL || 'MCPI VS Agent',
      autoAcceptConnection: true,
      autoAcceptInvitation: true,
    })

    if (!connectionRecord) {
      throw new Error('No connection record returned from receiveInvitationFromUrl')
    }

    console.log(
      JSON.stringify({
        status: 'request-sent',
        connectionId: connectionRecord.id,
        state: connectionRecord.state,
        invitationDid: connectionRecord.invitationDid,
      }),
    )

    await new Promise(resolve => setTimeout(resolve, 3000))
  } finally {
    await agent.shutdown().catch(() => undefined)
  }
}

main().catch(error => {
  const message = error instanceof Error ? error.stack || error.message : String(error)
  console.error(message)
  process.exit(1)
})
