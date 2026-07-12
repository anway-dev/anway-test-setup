'use strict'
const express = require('express')
const client = require('prom-client')

const app = express()
app.use(express.json())

const register = new client.Registry()
client.collectDefaultMetrics({ register })
const httpRequests = new client.Counter({ name: 'http_requests_total', help: 'Total HTTP requests', labelNames: ['method', 'route', 'status'], registers: [register] })
const ordersCreated = new client.Counter({ name: 'orders_created_total', help: 'Orders created', registers: [register] })
const orderValue = new client.Histogram({ name: 'order_value_dollars', help: 'Order value in dollars', buckets: [10, 50, 100, 250, 500, 1000], registers: [register] })

const orders = new Map()
let seq = 1

const PAYMENT_URL = process.env.PAYMENT_SERVICE_URL || 'http://payment-service:3000'
const INVENTORY_URL = process.env.INVENTORY_SERVICE_URL || 'http://inventory-service:3000'
const NOTIFICATION_URL = process.env.NOTIFICATION_SERVICE_URL || 'http://notification-service:3000'

app.use((req, res, next) => {
  res.on('finish', () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode })
    console.log(JSON.stringify({ time: new Date().toISOString(), method: req.method, path: req.path, status: res.statusCode, service: 'order-service' }))
  })
  next()
})

app.post('/orders', async (req, res) => {
  const { userId, items, total } = req.body || {}
  if (!userId || !items) return res.status(400).json({ error: 'userId and items required' })

  const orderId = `ord-${seq++}`
  const order = { id: orderId, userId, items, total: total || 0, status: 'pending', createdAt: new Date().toISOString() }
  orders.set(orderId, order)
  ordersCreated.inc()
  orderValue.observe(total || 0)

  // Fire-and-forget downstream calls (in prod these would be events)
  fetch(`${PAYMENT_URL}/charge`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ orderId, amount: total }) }).catch(() => {})
  fetch(`${INVENTORY_URL}/reserve`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ orderId, items }) }).catch(() => {})
  fetch(`${NOTIFICATION_URL}/send`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ userId, event: 'order_created', orderId }) }).catch(() => {})

  res.status(201).json(order)
})

app.get('/orders/:id', (req, res) => {
  const o = orders.get(req.params.id)
  if (!o) return res.status(404).json({ error: 'order not found' })
  res.json(o)
})

app.get('/orders', (req, res) => {
  const { userId } = req.query
  const list = [...orders.values()].filter(o => !userId || o.userId === userId)
  res.json({ orders: list })
})

app.get('/health', (_, res) => res.json({ status: 'ok', service: 'order-service' }))
app.get('/metrics', async (_, res) => { res.set('Content-Type', register.contentType); res.end(await register.metrics()) })

const PORT = process.env.PORT || 3000
app.listen(PORT, () => console.log(JSON.stringify({ time: new Date().toISOString(), msg: 'order-service started', port: PORT })))
