import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8')

test('Stripe webhook bypasses Supabase JWT only because it verifies Stripe HMAC first', () => {
  const config = read('supabase/config.toml')
  const webhook = read('supabase/functions/billing-webhook/index.ts')

  assert.match(config, /\[functions\.billing-checkout\]\s+verify_jwt = true/)
  assert.match(config, /\[functions\.billing-webhook\]\s+verify_jwt = false/)

  const signatureCheck = webhook.indexOf('verifyStripeSignature(rawBody, signature, webhookSecret)')
  const jsonParse = webhook.indexOf('JSON.parse(rawBody)')
  const dbClient = webhook.indexOf('createClient(supabaseUrl, serviceRoleKey')
  assert.ok(signatureCheck >= 0)
  assert.ok(jsonParse > signatureCheck)
  assert.ok(dbClient > signatureCheck)
})

test('Stripe Checkout authenticates the Supabase user before creating a Checkout Session', () => {
  const checkout = read('supabase/functions/billing-checkout/index.ts')
  const authenticate = checkout.indexOf('admin.auth.getUser(token)')
  const createCheckout = checkout.indexOf("'/v1/checkout/sessions'")
  assert.ok(authenticate >= 0)
  assert.ok(createCheckout > authenticate)
  assert.match(checkout, /effective_plan !== 'free'/)
  assert.match(checkout, /subscription_data\[trial_period_days\].*10/)
})

test('staging and production deploy only explicitly approved billing functions', () => {
  const stagingScript = read('scripts/deploy-staging-db.mjs')
  const productionWorkflow = read('.github/workflows/supabase-deploy.yaml')
  for (const name of ['billing-checkout', 'billing-webhook']) {
    assert.ok(stagingScript.includes(`'${name}'`))
    assert.ok(productionWorkflow.includes(name))
  }
})
