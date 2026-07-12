'use strict'
/**
 * Chaos runner — injects realistic failures into the demo stack.
 * Runs as a K8s Deployment with in-cluster RBAC.
 * Faults: pod kills, latency injection, error rate spikes, resource pressure.
 *
 * All config from env — no hardcoded targets or secrets.
 */

const { execSync } = require('child_process')

const NAMESPACE = process.env.K8S_NAMESPACE || 'demo'
const INTENSITY = parseFloat(process.env.CHAOS_INTENSITY || '0.3')  // 0.0–1.0
const INTERVAL_MS = parseInt(process.env.CHAOS_INTERVAL_MS || '30000')

const SERVICES = [
  'api-gateway', 'auth-service', 'user-service', 'product-service',
  'cart-service', 'order-service', 'payment-service', 'inventory-service',
  'notification-service', 'search-service', 'recommendation-service',
  'review-service', 'shipping-service', 'analytics-service', 'admin-service',
]

function kubectl(cmd) {
  try {
    return execSync(`kubectl ${cmd} -n ${NAMESPACE}`, { encoding: 'utf8', timeout: 10000 })
  } catch (e) {
    return null
  }
}

function log(event, details = {}) {
  console.log(JSON.stringify({ time: new Date().toISOString(), service: 'chaos-runner', event, ...details }))
}

// Fault 1: Kill a random pod
function killPod() {
  const svc = SERVICES[Math.floor(Math.random() * SERVICES.length)]
  const pods = kubectl(`get pods -l app=${svc} -o jsonpath='{.items[*].metadata.name}'`)
  if (!pods) return
  const podList = pods.trim().split(/\s+/).filter(Boolean)
  if (podList.length === 0) return
  const pod = podList[Math.floor(Math.random() * podList.length)]
  kubectl(`delete pod ${pod} --grace-period=0 --force`)
  log('pod_killed', { svc, pod })
}

// Fault 2: Scale a service to 0 briefly then restore
async function scaleZero() {
  const svc = SERVICES[Math.floor(Math.random() * SERVICES.length)]
  const current = kubectl(`get deployment ${svc} -o jsonpath='{.spec.replicas}'`)
  const replicas = parseInt(current || '1')
  kubectl(`scale deployment ${svc} --replicas=0`)
  log('scaled_to_zero', { svc, previousReplicas: replicas })
  await new Promise(r => setTimeout(r, 15000 + Math.random() * 15000))
  kubectl(`scale deployment ${svc} --replicas=${replicas}`)
  log('scaled_restored', { svc, replicas })
}

// Fault 3: Generate high CPU load via a transient pod
function cpuPressure() {
  const node = 'stress'
  kubectl(`run chaos-stress-${Date.now()} --image=polinux/stress --restart=Never --rm -i -- stress --cpu 2 --timeout 20s`)
  log('cpu_pressure_injected')
}

// Fault 4: Network partition simulation via pod label removal (drops from Service LB)
function networkPartition() {
  const svc = SERVICES[Math.floor(Math.random() * SERVICES.length)]
  const pods = kubectl(`get pods -l app=${svc} -o jsonpath='{.items[0].metadata.name}'`)
  if (!pods) return
  const pod = pods.trim()
  kubectl(`label pod ${pod} app-  `)  // remove app label → drops from Service endpoints
  log('network_partition_start', { svc, pod })
  setTimeout(() => {
    kubectl(`label pod ${pod} app=${svc}`)
    log('network_partition_end', { svc, pod })
  }, 10000 + Math.random() * 20000)
}

const FAULTS = [
  { weight: 50, name: 'kill_pod',          fn: killPod },
  { weight: 20, name: 'scale_zero',         fn: scaleZero },
  { weight: 15, name: 'cpu_pressure',       fn: cpuPressure },
  { weight: 15, name: 'network_partition',  fn: networkPartition },
]
const totalWeight = FAULTS.reduce((s, f) => s + f.weight, 0)

function pickFault() {
  let r = Math.random() * totalWeight
  for (const f of FAULTS) { r -= f.weight; if (r <= 0) return f }
  return FAULTS[0]
}

async function tick() {
  if (Math.random() > INTENSITY) return  // skip based on intensity
  const fault = pickFault()
  log('fault_start', { fault: fault.name })
  try {
    await fault.fn()
  } catch (e) {
    log('fault_error', { fault: fault.name, error: String(e) })
  }
}

async function run() {
  log('chaos_runner_started', { namespace: NAMESPACE, intensity: INTENSITY, intervalMs: INTERVAL_MS })
  // Initial delay — let services stabilise first
  await new Promise(r => setTimeout(r, 60000))
  setInterval(tick, INTERVAL_MS)
}

run()
