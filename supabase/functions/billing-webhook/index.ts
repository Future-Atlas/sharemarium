import { createClient } from 'npm:@supabase/supabase-js@2'
import {
  describeStripePrice,
  invoicePeriod,
  invoicePriceId,
  profileIdFromMetadata,
  sha256Hex,
  STRIPE_PROVIDER,
  stripeCustomerId,
  subscriptionPeriodEnd,
  subscriptionPriceId,
  toIsoFromUnix,
  verifyStripeSignature,
} from '../_shared/stripe_billing.mjs'

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })

  const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET')
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!webhookSecret || !supabaseUrl || !serviceRoleKey) {
    return new Response('Billing webhook is not configured', { status: 503 })
  }

  const rawBody = await request.text()
  const signature = request.headers.get('Stripe-Signature')
  if (!await verifyStripeSignature(rawBody, signature, webhookSecret)) {
    return new Response('Invalid signature', { status: 400 })
  }

  let event: any
  try {
    event = JSON.parse(rawBody)
  } catch {
    return new Response('Invalid JSON', { status: 400 })
  }
  if (!event?.id || !event?.type || !event?.data?.object) {
    return new Response('Invalid Stripe event', { status: 400 })
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const object = event.data.object
  const eventCreatedAt = toIsoFromUnix(event.created) ?? new Date().toISOString()
  const payloadHash = await sha256Hex(rawBody)

  try {
    const outcome = await normalizeEvent(admin, event.type, object)
    if (!outcome) return Response.json({ received: true, ignored: true })

    const profileId = outcome.profileId ?? await resolveProfile(admin, object)
    if (!profileId) throw new Error('No Sharemarium profile is linked to the Stripe event')

    const { data: claimRows, error: claimError } = await admin.rpc(
      'claim_billing_webhook_event',
      {
        incoming_provider: STRIPE_PROVIDER,
        incoming_event_id: event.id,
        incoming_event_type: event.type,
        incoming_normalized_type: outcome.normalizedType,
        incoming_profile_id: profileId,
        incoming_payload_sha256: payloadHash,
        incoming_provider_created_at: eventCreatedAt,
      },
    )
    if (claimError) throw claimError
    const claim = Array.isArray(claimRows) ? claimRows[0] : claimRows
    if (!claim?.webhook_event_id) throw new Error('Unable to claim billing event')
    if (claim.should_process !== true) {
      return Response.json({ received: true, duplicate: true, status: claim.event_status })
    }

    const eventId = claim.webhook_event_id
    try {
      if (outcome.action === 'ignore') {
        const { error } = await admin.rpc('ignore_billing_webhook_event', {
          webhook_event_id: eventId,
          note: outcome.note,
        })
        if (error) throw error
      } else {
        const { error } = await admin.rpc('apply_normalized_subscription_event', {
          webhook_event_id: eventId,
          target_profile_id: profileId,
          target_plan: outcome.plan,
          target_period_end: outcome.periodEnd,
          target_scheduled_plan: null,
          target_scheduled_effective_at: null,
          target_payment_grace_until: null,
          target_provider_customer_id: outcome.customerId,
        })
        if (error) throw error
      }
    } catch (processingError) {
      await admin.rpc('mark_billing_webhook_event_failed', {
        webhook_event_id: eventId,
        error_detail: safeError(processingError),
      })
      throw processingError
    }

    return Response.json({ received: true, processed: outcome.action !== 'ignore' })
  } catch (error) {
    console.error('Stripe webhook processing failed', safeError(error))
    return new Response('Webhook processing failed', { status: 500 })
  }
})

async function normalizeEvent(admin: any, type: string, object: any) {
  if (type.startsWith('customer.subscription.')) {
    const customerId = stripeCustomerId(object)
    const subscriptionId = object?.id?.toString()
    const profileId = profileIdFromMetadata(object) ??
      (customerId ? await profileForCustomer(admin, customerId) : null)
    if (!profileId || !customerId || !subscriptionId) {
      throw new Error('Stripe subscription is missing Sharemarium identity metadata')
    }
    const { error: linkError } = await admin.rpc('link_billing_provider_identity', {
      target_profile: profileId,
      target_provider: STRIPE_PROVIDER,
      target_customer_id: customerId,
      target_subscription_id: subscriptionId,
    })
    if (linkError) throw linkError

    const price = describeStripePrice(stripeEnv(), subscriptionPriceId(object))
    const periodEnd = toIsoFromUnix(subscriptionPeriodEnd(object))

    if (type === 'customer.subscription.deleted') {
      return {
        action: 'apply', normalizedType: 'subscription.canceled', profileId,
        customerId, plan: null, periodEnd,
      }
    }
    if (type === 'customer.subscription.created') {
      if (object.status === 'trialing') {
        if (!price) throw new Error('Stripe subscription uses an unknown price')
        return {
          action: 'apply', normalizedType: 'subscription.trial_started', profileId,
          customerId, plan: price.plan, periodEnd: null,
        }
      }
      return {
        action: 'ignore', normalizedType: 'ignored', profileId,
        customerId, plan: null, periodEnd: null,
        note: 'subscription_created_waiting_for_paid_invoice',
      }
    }
    if (type === 'customer.subscription.updated') {
      if (object.cancel_at_period_end === true) {
        if (!periodEnd) throw new Error('Scheduled cancellation is missing current period end')
        return {
          action: 'apply', normalizedType: 'subscription.cancel_scheduled', profileId,
          customerId, plan: null, periodEnd,
        }
      }
      return {
        action: 'ignore', normalizedType: 'ignored', profileId,
        customerId, plan: null, periodEnd: null,
        note: `subscription_update_${object.status ?? 'unknown'}_awaiting_authoritative_event`,
      }
    }
    return null
  }

  if (type === 'invoice.payment_failed' || type === 'invoice.paid') {
    const customerId = stripeCustomerId(object)
    if (!customerId) throw new Error('Stripe invoice is missing customer id')
    const profileId = await profileForCustomer(admin, customerId)
    if (!profileId) throw new Error('Stripe invoice customer is not linked to Sharemarium')

    const price = describeStripePrice(stripeEnv(), invoicePriceId(object))
    const period = invoicePeriod(object)
    const periodEnd = toIsoFromUnix(period.end)

    if (type === 'invoice.paid') {
      if (Number(object.amount_paid ?? 0) <= 0) {
        return {
          action: 'ignore', normalizedType: 'ignored', profileId,
          customerId, plan: null, periodEnd: null,
          note: 'zero_amount_invoice_does_not_activate_paid_access',
        }
      }
      if (!price || !periodEnd) throw new Error('Paid Stripe invoice uses an unknown price or period')
      return {
        action: 'apply', normalizedType: 'subscription.payment_recovered', profileId,
        customerId, plan: price.plan, periodEnd,
      }
    }

    return {
      action: 'apply', normalizedType: 'subscription.payment_failed', profileId,
      customerId, plan: null, periodEnd,
    }
  }

  return null
}

async function resolveProfile(admin: any, object: any) {
  const metadataProfile = profileIdFromMetadata(object)
  if (metadataProfile) return metadataProfile
  const customerId = stripeCustomerId(object)
  return customerId ? await profileForCustomer(admin, customerId) : null
}

async function profileForCustomer(admin: any, customerId: string) {
  const { data, error } = await admin.rpc('billing_profile_for_provider_customer', {
    target_provider: STRIPE_PROVIDER,
    target_customer_id: customerId,
  })
  if (error) throw error
  return typeof data === 'string' && data ? data : null
}

function stripeEnv(): Record<string, string | undefined> {
  return {
    STRIPE_PRICE_PLUS_MONTHLY: Deno.env.get('STRIPE_PRICE_PLUS_MONTHLY'),
    STRIPE_PRICE_PLUS_ANNUAL: Deno.env.get('STRIPE_PRICE_PLUS_ANNUAL'),
    STRIPE_PRICE_PREMIUM_MONTHLY: Deno.env.get('STRIPE_PRICE_PREMIUM_MONTHLY'),
    STRIPE_PRICE_PREMIUM_ANNUAL: Deno.env.get('STRIPE_PRICE_PREMIUM_ANNUAL'),
  }
}

function safeError(error: unknown) {
  return error instanceof Error ? error.message.slice(0, 500) : 'Unknown billing webhook error'
}
