const encoder = new TextEncoder()

export const STRIPE_PROVIDER = 'stripe'

export function stripePriceCatalog(env) {
  const definitions = [
    ['STRIPE_PRICE_PLUS_MONTHLY', 'plus', 'monthly'],
    ['STRIPE_PRICE_PLUS_ANNUAL', 'plus', 'annual'],
    ['STRIPE_PRICE_PREMIUM_MONTHLY', 'premium', 'monthly'],
    ['STRIPE_PRICE_PREMIUM_ANNUAL', 'premium', 'annual'],
  ]
  const catalog = new Map()
  for (const [key, plan, billingPeriod] of definitions) {
    const priceId = env[key]?.trim()
    if (!priceId) continue
    if (catalog.has(priceId)) {
      throw new Error('Stripe price IDs must be unique')
    }
    catalog.set(priceId, { priceId, plan, billingPeriod })
  }
  return catalog
}

export function requireStripePrice(env, plan, billingPeriod) {
  if (!['plus', 'premium'].includes(plan)) {
    throw new Error('Unsupported subscription plan')
  }
  if (!['monthly', 'annual'].includes(billingPeriod)) {
    throw new Error('Unsupported billing period')
  }
  const key = `STRIPE_PRICE_${plan.toUpperCase()}_${billingPeriod.toUpperCase()}`
  const priceId = env[key]?.trim()
  if (!priceId) throw new Error(`Missing Stripe price configuration: ${key}`)
  return priceId
}

export function describeStripePrice(env, priceId) {
  if (!priceId) return null
  return stripePriceCatalog(env).get(String(priceId)) ?? null
}

export function profileIdFromMetadata(object) {
  const candidate = object?.metadata?.sharemarium_profile_id
  if (typeof candidate !== 'string') return null
  const normalized = candidate.trim().toLowerCase()
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(normalized)
    ? normalized
    : null
}

export function stripeObjectId(value) {
  if (typeof value === 'string') return value
  return typeof value?.id === 'string' ? value.id : null
}

export function stripeCustomerId(object) {
  return stripeObjectId(object?.customer)
}

export function stripeSubscriptionId(object) {
  return stripeObjectId(object?.subscription)
}

export function stripePaymentIntentId(object) {
  return stripeObjectId(object?.payment_intent)
}

export function stripeRefundChargeId(object) {
  return stripeObjectId(object?.charge)
}

export function normalizeStripeChargeEventType(eventType) {
  switch (eventType) {
    case 'charge.pending': return 'charge.pending'
    case 'charge.succeeded': return 'charge.paid'
    case 'charge.failed': return 'charge.failed'
    case 'charge.expired': return 'charge.void'
    default: return null
  }
}

export function subscriptionPriceId(subscription) {
  const item = subscription?.items?.data?.[0]
  return stripeObjectId(item?.price)
}

export function subscriptionPeriodEnd(subscription) {
  const direct = positiveUnix(subscription?.current_period_end)
  if (direct) return direct
  const periods = Array.isArray(subscription?.items?.data)
    ? subscription.items.data
        .map((item) => positiveUnix(item?.current_period_end))
        .filter(Boolean)
    : []
  return periods.length ? Math.max(...periods) : null
}

export function invoiceSubscriptionLine(invoice) {
  const lines = Array.isArray(invoice?.lines?.data) ? invoice.lines.data : []
  return lines.find((line) =>
    line?.type === 'subscription' ||
    line?.parent?.type === 'subscription_item_details' ||
    line?.subscription != null
  ) ?? lines[0] ?? null
}

export function invoicePriceId(invoice) {
  const line = invoiceSubscriptionLine(invoice)
  return stripeObjectId(line?.price) ?? stripeObjectId(line?.pricing?.price_details?.price)
}

export function invoicePeriod(invoice) {
  const line = invoiceSubscriptionLine(invoice)
  const start = positiveUnix(line?.period?.start)
  const end = positiveUnix(line?.period?.end)
  return { start, end }
}

export function normalizeStripeRefundStatus(status) {
  switch (status) {
    case 'succeeded': return 'refund.succeeded'
    case 'failed': return 'refund.failed'
    case 'canceled': return 'refund.canceled'
    case 'pending':
    case 'requires_action':
      return 'refund.pending'
    default:
      return null
  }
}

export function normalizeStripeRefundReason(reason) {
  switch (reason) {
    case 'duplicate': return 'duplicate_charge'
    case 'fraudulent': return 'fraud'
    default: return 'other'
  }
}

export async function sha256Hex(value) {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(value))
  return bytesToHex(new Uint8Array(digest))
}

export async function verifyStripeSignature(rawBody, signatureHeader, secret, options = {}) {
  if (!secret || !signatureHeader) return false
  const toleranceSeconds = options.toleranceSeconds ?? 300
  const nowSeconds = options.nowSeconds ?? Math.floor(Date.now() / 1000)
  const parts = String(signatureHeader).split(',').map((part) => part.trim())
  const timestampPart = parts.find((part) => part.startsWith('t='))
  const signatures = parts
    .filter((part) => part.startsWith('v1='))
    .map((part) => part.slice(3).toLowerCase())
  if (!timestampPart || signatures.length === 0) return false

  const timestamp = Number(timestampPart.slice(2))
  if (!Number.isInteger(timestamp) || timestamp <= 0) return false
  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) return false

  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signedPayload = `${timestamp}.${rawBody}`
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(signedPayload))
  const expected = bytesToHex(new Uint8Array(signature))
  return signatures.some((candidate) => timingSafeHexEqual(candidate, expected))
}

export function toIsoFromUnix(value) {
  const unix = positiveUnix(value)
  return unix ? new Date(unix * 1000).toISOString() : null
}

export function formBody(entries) {
  const body = new URLSearchParams()
  for (const [key, value] of entries) {
    if (value === undefined || value === null || value === '') continue
    body.append(key, String(value))
  }
  return body
}

function positiveUnix(value) {
  const number = Number(value)
  return Number.isFinite(number) && number > 0 ? Math.trunc(number) : null
}

function timingSafeHexEqual(left, right) {
  if (!/^[0-9a-f]+$/.test(left) || left.length !== right.length) return false
  let result = 0
  for (let index = 0; index < left.length; index += 1) {
    result |= left.charCodeAt(index) ^ right.charCodeAt(index)
  }
  return result === 0
}

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
}
