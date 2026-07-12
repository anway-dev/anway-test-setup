'use strict'
/**
 * Traffic simulator — generates realistic e-commerce load against the demo stack.
 * Runs as a K8s CronJob or long-running Deployment.
 * All config via env vars — no secrets in code.
 */

const GATEWAY = process.env.GATEWAY_URL || 'http://api-gateway:8080'
const RPS = parseInt(process.env.RPS || '10')
const DURATION_MS = parseInt(process.env.DURATION_MS || '0')  // 0 = run forever

const PRODUCT_IDS = Array.from({ length: 50 }, (_, i) => `prod-${i + 1}`)
const USER_EMAILS = Array.from({ length: 20 }, (_, i) => `user${i + 1}@demo.test`)

let requestCount = 0
let errorCount = 0
let startTime = Date.now()

function pick(arr) { return arr[Math.floor(Math.random() * arr.length)] }
function rand(min, max) { return Math.floor(Math.random() * (max - min + 1)) + min }

async function post(path, body) {
  const res = await fetch(`${GATEWAY}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(5000),
  })
  requestCount++
  if (!res.ok) errorCount++
  return res
}

async function get(path) {
  const res = await fetch(`${GATEWAY}${path}`, { signal: AbortSignal.timeout(5000) })
  requestCount++
  if (!res.ok) errorCount++
  return res
}

// Weighted scenario selection
const SCENARIOS = [
  { weight: 40, run: browse },
  { weight: 25, run: search },
  { weight: 20, run: purchase },
  { weight: 10, run: checkout },
  { weight: 5,  run: adminCheck },
]

const totalWeight = SCENARIOS.reduce((s, sc) => s + sc.weight, 0)

function pickScenario() {
  let r = Math.random() * totalWeight
  for (const sc of SCENARIOS) {
    r -= sc.weight
    if (r <= 0) return sc.run
  }
  return SCENARIOS[0].run
}

async function browse() {
  await get('/api/product/products?limit=10')
  await get(`/api/product/products/${pick(PRODUCT_IDS)}`)
  await get(`/api/review/${pick(PRODUCT_IDS)}/reviews`)
}

async function search() {
  await get(`/api/search/search?q=${encodeURIComponent(pick(['laptop', 'shirt', 'book', 'phone', 'food']))}`)
  await get('/api/recommendation/recommendations?userId=' + pick(USER_EMAILS))
}

async function purchase() {
  const email = pick(USER_EMAILS)
  const loginRes = await post('/api/auth/login', { email, password: 'demo' })
  if (!loginRes.ok) return
  const productId = pick(PRODUCT_IDS)
  await post('/api/cart/items', { userId: email, productId, quantity: rand(1, 3) })
  await get(`/api/cart?userId=${email}`)
}

async function checkout() {
  const email = pick(USER_EMAILS)
  const items = [{ productId: pick(PRODUCT_IDS), quantity: rand(1, 2) }]
  const total = parseFloat((Math.random() * 300 + 20).toFixed(2))
  await post('/api/order/orders', { userId: email, items, total })
}

async function adminCheck() {
  await get('/api/analytics/summary')
  await get('/api/admin/dashboard')
}

async function tick() {
  try {
    const scenario = pickScenario()
    await scenario()
  } catch {
    errorCount++
  }
}

function printStats() {
  const elapsed = (Date.now() - startTime) / 1000
  const rps = requestCount / elapsed
  const errorRate = requestCount > 0 ? (errorCount / requestCount * 100).toFixed(1) : '0.0'
  console.log(JSON.stringify({ time: new Date().toISOString(), requests: requestCount, errors: errorCount, rps: rps.toFixed(1), errorRate: `${errorRate}%`, service: 'traffic-simulator' }))
}

async function run() {
  console.log(JSON.stringify({ time: new Date().toISOString(), msg: 'traffic-simulator started', gateway: GATEWAY, rps: RPS }))
  const intervalMs = 1000 / RPS
  setInterval(tick, intervalMs)
  setInterval(printStats, 10000)
  if (DURATION_MS > 0) setTimeout(() => { printStats(); process.exit(0) }, DURATION_MS)
}

run()
