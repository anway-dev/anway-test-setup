'use strict'
const express = require('express')
const client = require('prom-client')

const app = express()
app.use(express.json())

const register = new client.Registry()
client.collectDefaultMetrics({ register })
const httpRequests = new client.Counter({ name: 'http_requests_total', help: 'Total HTTP requests', labelNames: ['method', 'route', 'status'], registers: [register] })

const SERVICE_NAME = 'shipping-service'
const store = new Map()
let seq = 1

app.use((req, res, next) => {
  res.on('finish', () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode })
    console.log(JSON.stringify({ time: new Date().toISOString(), method: req.method, path: req.path, status: res.statusCode, service: SERVICE_NAME }))
  })
  next()
})

app.get('/', (_, res) => res.json({ service: SERVICE_NAME, version: process.env.APP_VERSION || '1.0.0' }))
app.post('/*', (req, res) => {
  const id = `${SERVICE_NAME}-${seq++}`
  store.set(id, { id, ...req.body, createdAt: new Date().toISOString() })
  res.status(201).json({ id, status: 'ok' })
})
app.get('/health', (_, res) => res.json({ status: 'ok', service: SERVICE_NAME }))
app.get('/metrics', async (_, res) => { res.set('Content-Type', register.contentType); res.end(await register.metrics()) })
app.get('/:id', (req, res) => {
  const item = store.get(req.params.id)
  if (!item) return res.status(404).json({ error: 'not found' })
  res.json(item)
})

const PORT = process.env.PORT || 3000
app.listen(PORT, () => console.log(JSON.stringify({ time: new Date().toISOString(), msg: SERVICE_NAME + ' started', port: PORT })))
