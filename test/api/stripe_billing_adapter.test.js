import test from 'node:test'
import assert from 'node:assert/strict'
import { createHmac, webcrypto } from 'node:crypto'

if (!globalThis.crypto) globalThis.crypto = webcrypto

const {
  describeStripePrice,
  invoicePeriod,
  normalizeStripeRefundReason,
  normalizeStripeRefundStatus,
  profileIdFromMetadata,
  requireStripePrice,
  subscriptionPeriodEnd,
  verifyStripeSignature,
} = await import('../../supabase/functions/_shared/stripe_billing.mjs')

const env = {
  STRIPE_PRICE_PLUS_MONTHLY: 'price_plus_monthly',
  STRIPE_PRICE_PLUS_ANNUAL: 'price_plus_annual',
  STRIPE_PRICE_PREMIUM_MONTHLY: 'price_premium_monthly',
  STRIPE_PRICE_PREMIUM_ANNUAL: 'price_premium_annual',
}

test('maps configured Stripe prices to Sharemarium plans', () => {
  assert.deepEqual(describeStripePrice(env, 'price_plus_annual'), {
    priceId: 'price_plus_annual',
    plan: 'plus',
    billingPeriod: 'annual',
  })
  assert.equal(requireStripePrice(env, 'premium', 'monthly'), 'price_premium_monthly')
  assert.equal(describeStripePrice(env, 'price_unknown'), null)
})

test('rejects invalid plan and missing price configuration', () => {
  assert.throws(() => requireStripePrice(env, 'free', 'monthly'), /Unsupported subscription plan/)
  assert.throws(
    () => requireStripePrice({}, 'plus', 'annual'),
    /Missing Stripe price configuration/,
  )
})

test('extracts validated Sharemarium profile metadata', () => {
  const id = '7a000000-0000-4000-8000-000000000001'
  assert.equal(profileIdFromMetadata({ metadata: { sharemarium_profile_id: id } }), id)
  assert.equal(profileIdFromMetadata({ metadata: { sharemarium_profile_id: 'not-a-uuid' } }), null)
})

test('extracts period ends from old and item-based Stripe subscription shapes', () => {
  assert.equal(subscriptionPeriodEnd({ current_period_end: 200 }), 200)
  assert.equal(
    subscriptionPeriodEnd({
      items: { data: [{ current_period_end: 150 }, { current_period_end: 220 }] },
    }),
    220,
  )
  assert.equal(subscriptionPeriodEnd({}), null)
})

test('extracts invoice period from subscription line', () => {
  assert.deepEqual(
    invoicePeriod({
      lines: {
        data: [
          { type: 'invoiceitem', period: { start: 1, end: 2 } },
          { type: 'subscription', period: { start: 100, end: 200 } },
        ],
      },
    }),
    { start: 100, end: 200 },
  )
})

test('maps Stripe refund states and reasons conservatively', () => {
  assert.equal(normalizeStripeRefundStatus('succeeded'), 'refund.succeeded')
  assert.equal(normalizeStripeRefundStatus('requires_action'), 'refund.pending')
  assert.equal(normalizeStripeRefundStatus('mystery'), null)
  assert.equal(normalizeStripeRefundReason('duplicate'), 'duplicate_charge')
  assert.equal(normalizeStripeRefundReason('fraudulent'), 'fraud')
  assert.equal(normalizeStripeRefundReason('requested_by_customer'), 'other')
})

test('verifies Stripe webhook HMAC and timestamp tolerance', async () => {
  const secret = 'whsec_test_secret'
  const timestamp = 2_000_000_000
  const body = JSON.stringify({ id: 'evt_test', type: 'customer.subscription.created' })
  const signature = createHmac('sha256', secret)
    .update(`${timestamp}.${body}`)
    .digest('hex')
  const header = `t=${timestamp},v1=${signature}`

  assert.equal(
    await verifyStripeSignature(body, header, secret, { nowSeconds: timestamp + 120 }),
    true,
  )
  assert.equal(
    await verifyStripeSignature(`${body}x`, header, secret, { nowSeconds: timestamp }),
    false,
  )
  assert.equal(
    await verifyStripeSignature(body, header, secret, { nowSeconds: timestamp + 301 }),
    false,
  )
})
