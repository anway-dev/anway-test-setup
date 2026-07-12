'use strict'
const express = require('express')
const jwt = require('jsonwebtoken')
const client = require('prom-client')

const app = express()
app.use(express.json())

const register = new client.Registry()
client.collectDefaultMetrics({ register })
const httpRequests = new client.Counter({ name: 'http_requests_total', help: 'Total HTTP requests', labelNames: ['method', 'route', 'status'], registers: [register] })
const authAttempts = new client.Counter({ name: 'auth_attempts_total', help: 'Auth attempts', labelNames: ['result'], registers: [register] })

const JWT_SECRET = process.env.JWT_SECRET  // required — from Secrets Manager via pod env
if (!JWT_SECRET) { console.error('JWT_SECRET not set'); process.exit(1) }

app.use((req, res, next) => {
  res.on('finish', () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode })
    console.log(JSON.stringify({ time: new Date().toISOString(), method: req.method, path: req.path, status: res.statusCode, service: 'auth-service' }))
  })
  next()
})

// POST /login
app.post('/login', (req, res) => {
  const { email, password } = req.body || {}
  if (!email || !password) { authAttempts.inc({ result: 'bad_request' }); return res.status(400).json({ error: 'email and password required' }) }
  // Demo: accept any non-empty creds
  const token = jwt.sign({ sub: email, email, role: email.includes('admin') ? 'admin' : 'user' }, JWT_SECRET, { expiresIn: '24h' })
  authAttempts.inc({ result: 'success' })
  res.json({ token, expiresIn: '24h' })
})

// POST /verify
app.post('/verify', (req, res) => {
  const { token } = req.body || {}
  if (!token) return res.status(400).json({ error: 'token required' })
  try {
    const payload = jwt.verify(token, JWT_SECRET)
    res.json({ valid: true, payload })
  } catch {
    authAttempts.inc({ result: 'invalid_token' })
    res.status(401).json({ valid: false, error: 'invalid or expired token' })
  }
})

// POST /refresh
app.post('/refresh', (req, res) => {
  const { token } = req.body || {}
  try {
    const payload = jwt.verify(token, JWT_SECRET)
    const newToken = jwt.sign({ sub: payload.sub, email: payload.email, role: payload.role }, JWT_SECRET, { expiresIn: '24h' })
    res.json({ token: newToken })
  } catch {
    res.status(401).json({ error: 'invalid token' })
  }
})

app.get('/health', (_, res) => res.json({ status: 'ok', service: 'auth-service' }))
app.get('/metrics', async (_, res) => { res.set('Content-Type', register.contentType); res.end(await register.metrics()) })

const PORT = process.env.PORT || 3000
app.listen(PORT, () => console.log(JSON.stringify({ time: new Date().toISOString(), msg: 'auth-service started', port: PORT })))
