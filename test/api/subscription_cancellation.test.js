import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const source = readFileSync(
  new URL('../../supabase/functions/billing-cancel-subscription/index.ts', import.meta.url),
  'utf8',
)

test('subscription cancellation authenticates before loading billing context', () => {
  const authenticate = source.indexOf('admin.auth.getUser(token)')
  const context = source.indexOf("'billing_provider_context'")
  const stripeLookup = source.indexOf("method: 'GET'")

  assert.ok(authenticate >= 0)
  assert.ok(context > authenticate)
  assert.ok(stripeLookup > context)
})

test('trial cancellation is immediate while paid cancellation is period-end', () => {
  const trialBranch = source.indexOf("subscription?.status === 'trialing'")
  const deleteCall = source.indexOf("'DELETE'", trialBranch)
  const scheduleBody = source.indexOf("body.set('cancel_at_period_end', 'true')")
  const postCall = source.indexOf("'POST'", scheduleBody)

  assert.ok(trialBranch >= 0)
  assert.ok(deleteCall > trialBranch)
  assert.ok(scheduleBody > deleteCall)
  assert.ok(postCall > scheduleBody)
  assert.match(source, /mode: 'immediate'/)
  assert.match(source, /mode: 'period_end'/)
})

test('cancellation validates the Stripe customer against the billing profile', () => {
  assert.match(source, /provider_customer_id/)
  assert.match(source, /Stripe subscription customer does not match billing profile/)
})

test('already canceled or scheduled subscriptions are idempotent', () => {
  assert.match(source, /mode: 'already_canceled'/)
  assert.match(source, /cancel_at_period_end === true/)
  assert.match(source, /mode: 'already_scheduled'/)
})

test('billing cancellation endpoint never trusts a client subscription id', () => {
  assert.doesNotMatch(source, /body\?\.subscriptionId/)
  assert.match(source, /provider_subscription_id/)
})
