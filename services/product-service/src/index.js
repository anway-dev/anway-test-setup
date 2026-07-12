'use strict'
const express = require('express')
const client = require('prom-client')

const app = express()
app.use(express.json())

const register = new client.Registry()
client.collectDefaultMetrics({ register })
const httpRequests = new client.Counter({ name: 'http_requests_total', help: 'Total HTTP requests', labelNames: ['method', 'route', 'status'], registers: [register] })

// In-memory demo catalog — real impl would use DB_URL from env
const products = Array.from({ length: 50 }, (_, i) => ({
  id: `prod-${i + 1}`,
  name: `Product ${i + 1}`,
  price: parseFloat((Math.random() * 200 + 10).toFixed(2)),
  stock: Math.floor(Math.random() * 100),
  category: ['electronics', 'clothing', 'books', 'food'][i % 4],
}))

app.use((req, res, next) => {
  res.on('finish', () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode })
    console.log(JSON.stringify({ time: new Date().toISOString(), method: req.method, path: req.path, status: res.statusCode, service: 'product-service' }))
  })
  next()
})

app.get('/products', (req, res) => {
  const { category, limit = '20', offset = '0' } = req.query
  let list = products
  if (category) list = list.filter(p => p.category === category)
  res.json({ products: list.slice(Number(offset), Number(offset) + Number(limit)), total: list.length })
})

app.get('/products/:id', (req, res) => {
  const p = products.find(p => p.id === req.params.id)
  if (!p) return res.status(404).json({ error: 'product not found' })
  res.json(p)
})

app.get('/health', (_, res) => res.json({ status: 'ok', service: 'product-service' }))
app.get('/metrics', async (_, res) => { res.set('Content-Type', register.contentType); res.end(await register.metrics()) })

const PORT = process.env.PORT || 3000
app.listen(PORT, () => console.log(JSON.stringify({ time: new Date().toISOString(), msg: 'product-service started', port: PORT })))
