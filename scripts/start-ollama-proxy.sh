#!/usr/bin/env bash

set -euo pipefail

LISTEN_HOST="${LISTEN_HOST:-127.0.0.1}"
LISTEN_PORT="${LISTEN_PORT:-18080}"
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
UPSTREAM_HOST_HEADER="${UPSTREAM_HOST_HEADER:-${OLLAMA_HOST}:${OLLAMA_PORT}}"

node <<'EOF'
const http = require('http')

const listenHost = process.env.LISTEN_HOST || '127.0.0.1'
const listenPort = Number.parseInt(process.env.LISTEN_PORT || '18080', 10)
const upstreamHost = process.env.OLLAMA_HOST || '127.0.0.1'
const upstreamPort = Number.parseInt(process.env.OLLAMA_PORT || '11434', 10)
const upstreamHostHeader = process.env.UPSTREAM_HOST_HEADER || `${upstreamHost}:${upstreamPort}`

const server = http.createServer((req, res) => {
  const proxy = http.request(
    {
      hostname: upstreamHost,
      port: upstreamPort,
      path: req.url,
      method: req.method,
      headers: {
        ...req.headers,
        host: upstreamHostHeader,
      },
    },
    (upstream) => {
      res.writeHead(upstream.statusCode || 502, upstream.headers)
      upstream.pipe(res)
    }
  )

  proxy.on('error', (error) => {
    res.statusCode = 502
    res.setHeader('content-type', 'text/plain; charset=utf-8')
    res.end(`proxy error: ${error.message}`)
  })

  req.pipe(proxy)
})

server.listen(listenPort, listenHost, () => {
  console.log(`Ollama proxy listening on http://${listenHost}:${listenPort}`)
  console.log(`Forwarding to http://${upstreamHost}:${upstreamPort} with Host=${upstreamHostHeader}`)
})
EOF
