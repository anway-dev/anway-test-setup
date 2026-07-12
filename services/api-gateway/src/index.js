'use strict'
const express = require('express')
const { createProxyMiddleware } = require('http-proxy-middleware')
const client = require('prom-client')

const app = express()
const register = new client.Registry()
client.collectDefaultMetrics({ register })

const httpRequests = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status'],
  registers: [register],
})
const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration',
  labelNames: ['method', 'route'],
  buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1, 2],
  registers: [register],
})

const UPSTREAM = {
  auth:           process.env.AUTH_SERVICE_URL           || 'http://auth-service:3000',
  user:           process.env.USER_SERVICE_URL           || 'http://user-service:3000',
  product:        process.env.PRODUCT_SERVICE_URL        || 'http://product-service:3000',
  cart:           process.env.CART_SERVICE_URL           || 'http://cart-service:3000',
  order:          process.env.ORDER_SERVICE_URL          || 'http://order-service:3000',
  payment:        process.env.PAYMENT_SERVICE_URL        || 'http://payment-service:3000',
  inventory:      process.env.INVENTORY_SERVICE_URL      || 'http://inventory-service:3000',
  notification:   process.env.NOTIFICATION_SERVICE_URL   || 'http://notification-service:3000',
  search:         process.env.SEARCH_SERVICE_URL         || 'http://search-service:3000',
  recommendation: process.env.RECOMMENDATION_SERVICE_URL || 'http://recommendation-service:3000',
  review:         process.env.REVIEW_SERVICE_URL         || 'http://review-service:3000',
  shipping:       process.env.SHIPPING_SERVICE_URL       || 'http://shipping-service:3000',
  analytics:      process.env.ANALYTICS_SERVICE_URL      || 'http://analytics-service:3000',
  admin:          process.env.ADMIN_SERVICE_URL          || 'http://admin-service:3000',
}

app.use((req, res, next) => {
  const end = httpDuration.startTimer({ method: req.method, route: req.path })
  res.on('finish', () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode })
    end()
    console.log(JSON.stringify({ time: new Date().toISOString(), method: req.method, path: req.path, status: res.statusCode, service: 'api-gateway' }))
  })
  next()
})

for (const [name, url] of Object.entries(UPSTREAM)) {
  app.use(`/api/${name}`, createProxyMiddleware({ target: url, changeOrigin: true, pathRewrite: { [`^/api/${name}`]: '' } }))
}

app.get('/health', (_, res) => res.json({ status: 'ok', service: 'api-gateway', upstreams: Object.keys(UPSTREAM) }))
app.get('/metrics', async (_, res) => { res.set('Content-Type', register.contentType); res.end(await register.metrics()) })
app.get('/', (_, res) => res.json({ service: 'api-gateway', version: process.env.APP_VERSION || '1.0.0' }))

const PORT = process.env.PORT || 8080
app.listen(PORT, () => console.log(JSON.stringify({ time: new Date().toISOString(), msg: 'api-gateway started', port: PORT })))
