import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8')

test('Stripe webhook bypasses Supabase JWT only because it verifies Stripe HMAC first', () => {
  const config = read('supabase/config.toml')
  const webhook = read('supabase/functions/billing-webhook/index.ts')

  assert.match(config, /\[functions\.billing-checkout\]\s+verify_jwt = true/)\n  assert.match(config, /\[functions\.billing-cancel-subscription\]\s+verify_jwt = true/)
  assert.match(config, /\[functions\.billing-webhook\]\s+verify_jwt = false/)

  const signatureCheck = webhook.indexOf('verifyStripeSignature(rawBody, signature, webhookSecret)')
  const jsonParse = webhook.indexOf('JSON.parse(rawBody)')
  const dbClient = webhook.indexOf('createClient(supabaseUrl, serviceRoleKey')
  const normalizeEvent = webhook.indexOf(
    'normalizeEvent(admin, event.type, object, stripeSecretKey)',
  )
  assert.ok(signatureCheck >= 0)
  assert.ok(jsonParse > signatureCheck)
  assert.ok(dbClient > signatureCheck)
  assert.ok(normalizeEvent > signatureCheck)
})

test('Stripe webhook routes charge and refund events into normalized audit RPCs', () => {
  const webhook = read('supabase/functions/billing-webhook/index.ts')

  assert.match(webhook, /apply_normalized_charge_event/)
  assert.match(webhook, /apply_normalized_refund_event/)
  assert.match(webhook, /\/v1\/invoice_payments/)
  assert.match(webhook, /payment\[payment_intent\]/)
  assert.match(webhook, /charge_for_unlinked_customer_ignored/)
})

test('Stripe Checkout authenticates the Supabase user before creating a Checkout Session', () => {
  const checkout = read('supabase/functions/billing-checkout/index.ts')
  const authenticate = checkout.indexOf('admin.auth.getUser(token)')
  const createCheckout = checkout.indexOf("'/v1/checkout/sessions'")
  assert.ok(authenticate >= 0)
  assert.ok(createCheckout > authenticate)
  assert.match(checkout, /effective_plan !== 'free'/)
  assert.match(checkout, /subscription_data\[trial_period_days\].*10/)
  assert.match(checkout, /valid checkout request ID is required/)
  assert.match(checkout, /sharemarium-checkout-\$\{requestId\}/)
  assert.doesNotMatch(
    checkout,
    /sharemarium-checkout-\$\{user\.id\}-\$\{plan\}/,
  )
})

test('staging and production deploy only explicitly approved billing functions', () => {
  const stagingScript = read('scripts/deploy-staging-db.mjs')
  const productionWorkflow = read('.github/workflows/supabase-deploy.yaml')
  for (const name of ['billing-checkout', 'billing-cancel-subscription', 'billing-webhook']) {
    assert.ok(stagingScript.includes(`'${name}'`))
    assert.ok(productionWorkflow.includes(name))
  }
})
