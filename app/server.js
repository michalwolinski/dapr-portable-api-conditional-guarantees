// Subscriber used to demonstrate at-least-once delivery. It deliberately
// fails the first FAIL_FIRST deliveries of every event and only then acks,
// so the redelivery is visible instead of inferred.
const http = require('node:http')

const PORT = Number(process.env.PORT || 8090)
const FAIL_FIRST = Number(process.env.FAIL_FIRST || 2)
const deliveries = new Map()

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200).end('ok')
    return
  }

  // Dapr asks the app for its subscription list when the app supports
  // programmatic subscriptions.
  if (req.method === 'GET' && req.url === '/dapr/subscribe') {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(
      JSON.stringify([
        { pubsubname: 'pubsub-redis', topic: 'orders', route: '/orders' },
      ])
    )
    return
  }

  if (req.method === 'POST' && req.url === '/orders') {
    let body = ''
    req.on('data', (chunk) => {
      body += chunk
    })
    req.on('end', () => {
      let event = {}
      try {
        event = JSON.parse(body || '{}')
      } catch {
        event = {}
      }
      const id = event.id || 'unknown'
      const count = (deliveries.get(id) || 0) + 1
      deliveries.set(id, count)

      const stamp = new Date().toISOString()
      if (count <= FAIL_FIRST) {
        console.log(`${stamp} delivery #${count} of ${id} -> 500 (deliberate)`)
        res.writeHead(500, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ error: 'deliberate failure' }))
        return
      }

      console.log(`${stamp} delivery #${count} of ${id} -> 200 (acked)`)
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ success: true }))
    })
    return
  }

  res.writeHead(404).end()
})

server.listen(PORT, () => console.log(`subscriber listening on ${PORT}`))
