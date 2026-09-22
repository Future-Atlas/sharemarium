import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const source = readFileSync(
  new URL('../../supabase/functions/delete-account/index.ts', import.meta.url),
  'utf8',
)

test('account deletion verifies billing state only after authenticating the user', () => {
  const authenticate = source.indexOf('admin.auth.getUser(token)')
  const billingContext = source.indexOf("'billing_provider_context'")
  const prepareDeletion = source.indexOf("'prepare_self_account_deletion'")

  assert.ok(authenticate >= 0)
  assert.ok(billingContext > authenticate)
  assert.ok(prepareDeletion > billingContext)
})

test('active Stripe subscription is canceled before deleting the auth user', () => {
  const lookup = source.indexOf("method: 'GET'")
  const cancel = source.indexOf("method: 'DELETE'")
  const deleteUser = source.indexOf('admin.auth.admin.deleteUser(profileId)')

  assert.ok(lookup >= 0)
  assert.ok(cancel > lookup)
  assert.ok(deleteUser > cancel)
  assert.match(source, /payload\?\.status === 'canceled'/)
  assert.match(source, /cancelPayload\?\.status !== 'canceled'/)
})

test('Stripe lookup failures block destructive account deletion', () => {
  assert.doesNotMatch(
    source,
    /lookupResponse\.status === 404[^]*return/,
  )
  assert.match(
    source,
    /Stripe subscription lookup failed with HTTP/,
  )
  assert.match(
    source,
    /Unable to cancel the active subscription before account deletion/,
  )
  assert.match(source, /rollbackDeletionPreparation/)
})

test('Stripe cancellation uses an idempotency key without requesting proration', () => {
  assert.match(source, /'Idempotency-Key': idempotencyKey/)
  assert.doesNotMatch(source, /invoice_now=true/)
  assert.doesNotMatch(source, /prorate=true/)
})
