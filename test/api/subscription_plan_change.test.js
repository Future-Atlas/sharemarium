import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const source = readFileSync(
  new URL('../../supabase/functions/billing-change-plan/index.ts', import.meta.url),
  'utf8',
)

test('plan change authenticates and resolves subscription identity server-side', () => {
  const authenticate = source.indexOf('admin.auth.getUser(token)')
  const billingContext = source.indexOf("'billing_provider_context'")
  const subscriptionId = source.indexOf('provider_subscription_id')
  const stripeLookup = source.indexOf("'GET'")

  assert.ok(authenticate >= 0)
  assert.ok(billingContext > authenticate)
  assert.ok(subscriptionId > billingContext)
  assert.ok(stripeLookup > subscriptionId)
  assert.doesNotMatch(source, /body\?\.subscriptionId/)
  assert.doesNotMatch(source, /body\?\.priceId/)
})

test('plan changes preserve billing period and schedule at renewal', () => {
  assert.match(source, /currentPrice\.billingPeriod/)
  assert.match(source, /requireStripePrice/)
  assert.match(source, /from_subscription/)
  assert.match(source, /phases\[0\]\[end_date\]/)
  assert.match(source, /phases\[1\]\[items\]\[0\]\[price\]/)
  assert.match(source, /phases\[1\]\[duration\]\[interval\]/)
  assert.match(source, /end_behavior.*release/)
})

test('plan schedule explicitly disables prorations', () => {
  const prorationMatches = source.match(/proration_behavior[^\n]*none/g) ?? []
  assert.ok(prorationMatches.length >= 3)
  assert.doesNotMatch(source, /always_invoice/)
})

test('advanced subscriptions fail closed instead of losing billing settings', () => {
  assert.match(source, /Only a simple one-item subscription/)
  assert.match(source, /advanced billing settings that require manual review/)
  assert.match(source, /add_invoice_items/)
  assert.match(source, /default_tax_rates/)
  assert.match(source, /discounts/)
  assert.match(source, /transfer_data/)
})

test('partially-created schedules are released when setup fails', () => {
  const createSchedule = source.indexOf("'/v1/subscription_schedules'")
  const updateSchedule = source.indexOf('/v1/subscription_schedules/\${encodeURIComponent(scheduleId)}')
  const rollback = source.indexOf('await releaseSchedule(scheduleId')

  assert.ok(createSchedule >= 0)
  assert.ok(updateSchedule > createSchedule)
  assert.ok(rollback > updateSchedule)
  assert.match(source, /\/release/)
})

test('plan change idempotency is scoped to a client-generated attempt', () => {
  assert.match(source, /valid plan change request ID/)
  assert.match(source, /sharemarium-plan-change-create-\$\{requestId\}/)
  assert.match(source, /sharemarium-plan-change-update-\$\{requestId\}/)
})
