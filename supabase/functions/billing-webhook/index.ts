import { createClient } from 'npm:@supabase/supabase-js@2'
import {
  describeStripePrice,
  invoicePeriod,
  invoicePriceId,
  normalizeStripeChargeEventType,
  normalizeStripeRefundReason,
  normalizeStripeRefundStatus,
  profileIdFromMetadata,
  sha256Hex,
  STRIPE_PROVIDER,
  stripeCustomerId,
  stripeObjectId,
  stripePaymentIntentId,
  stripeRefundChargeId,
  subscriptionPeriodEnd,
  subscriptionPriceId,
  toIsoFromUnix,
  verifyStripeSignature,
} from '../_shared/stripe_billing.mjs'

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })

  const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET')
  const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY')
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
    const outcome = await normalizeEvent(admin, event.type, object, stripeSecretKey)
    if (!outcome) return Response.json({ received: true, ignored: true })

    const profileId = outcome.profileId ??
      await resolveProfile(admin, object, stripeSecretKey)
    if (!profileId && outcome.requiresProfile !== false) {
      throw new Error('No Sharemarium profile is linked to the Stripe event')
    }

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
      } else if (outcome.processor === 'charge') {
        if (!profileId) throw new Error('Charge event requires a linked Sharemarium profile')
        const { error } = await admin.rpc('apply_normalized_charge_event', {
          input_webhook_event_id: eventId,
          target_profile_id: profileId,
          target_plan: outcome.plan,
          target_billing_period: outcome.billingPeriod,
          target_amount_minor: outcome.amountMinor,
          target_currency: outcome.currency,
          target_provider_charge_id: outcome.chargeId,
          target_provider_customer_id: outcome.customerId,
          target_provider_invoice_id: outcome.invoiceId,
          target_charged_at: outcome.chargedAt,
          target_period_start: outcome.periodStart,
          target_period_end: outcome.periodEnd,
        })
        if (error) throw error
      } else if (outcome.processor === 'refund') {
        const { error } = await admin.rpc('apply_normalized_refund_event', {
          input_webhook_event_id: eventId,
          target_provider_charge_id: outcome.chargeId,
          target_provider_refund_id: outcome.refundId,
          target_amount_minor: outcome.amountMinor,
          target_currency: outcome.currency,
          target_reason_code: outcome.reasonCode,
          target_reason_detail: outcome.reasonDetail,
          target_completed_at:
            outcome.normalizedType === 'refund.succeeded' ? eventCreatedAt : null,
        })
        if (error) throw error
      } else {
        if (!profileId) throw new Error('Subscription event requires a linked Sharemarium profile')
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

async function normalizeEvent(
  admin: any,
  type: string,
  object: any,
  stripeSecretKey?: string,
) {
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
        action: 'apply', processor: 'subscription',
        normalizedType: 'subscription.canceled', profileId,
        customerId, plan: null, periodEnd,
      }
    }
    if (type === 'customer.subscription.created') {
      if (object.status === 'trialing') {
        if (!price) throw new Error('Stripe subscription uses an unknown price')
        return {
          action: 'apply', processor: 'subscription',
          normalizedType: 'subscription.trial_started', profileId,
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
          action: 'apply', processor: 'subscription',
          normalizedType: 'subscription.cancel_scheduled', profileId,
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
      if (!price || !periodEnd) {
        throw new Error('Paid Stripe invoice uses an unknown price or period')
      }
      return {
        action: 'apply', processor: 'subscription',
        normalizedType: 'subscription.payment_recovered', profileId,
        customerId, plan: price.plan, periodEnd,
      }
    }

    return {
      action: 'apply', processor: 'subscription',
      normalizedType: 'subscription.payment_failed', profileId,
      customerId, plan: null, periodEnd,
    }
  }

  const normalizedChargeType = normalizeStripeChargeEventType(type)
  if (normalizedChargeType) {
    const customerId = stripeCustomerId(object)
    if (!customerId) {
      return {
        action: 'ignore', normalizedType: 'ignored', requiresProfile: false,
        note: 'charge_without_customer_ignored',
      }
    }
    const profileId = await profileForCustomer(admin, customerId)
    if (!profileId) {
      return {
        action: 'ignore', normalizedType: 'ignored', requiresProfile: false,
        note: 'charge_for_unlinked_customer_ignored',
      }
    }

    const chargeId = object?.id?.toString()
    const paymentIntentId = stripePaymentIntentId(object)
    if (!chargeId || !paymentIntentId) {
      return {
        action: 'ignore', normalizedType: 'ignored', profileId,
        note: 'charge_without_payment_intent_ignored',
      }
    }
    if (!stripeSecretKey) {
      throw new Error('Stripe secret key is required to resolve subscription charge context')
    }

    const invoicePayment = await findInvoicePaymentForPaymentIntent(
      stripeSecretKey,
      paymentIntentId,
    )
    if (!invoicePayment) {
      if (type === 'charge.succeeded') {
        throw new Error('Successful Stripe charge is not yet linked to an invoice payment')
      }
      return {
        action: 'ignore', normalizedType: 'ignored', profileId,
        note: 'non_successful_charge_without_invoice_payment_ignored',
      }
    }

    const invoiceId = stripeObjectId(invoicePayment.invoice)
    if (!invoiceId) throw new Error('Stripe invoice payment is missing invoice id')
    const invoice = await stripeGet(
      `/v1/invoices/${encodeURIComponent(invoiceId)}`,
      stripeSecretKey,
    )
    const price = describeStripePrice(stripeEnv(), invoicePriceId(invoice))
    const period = invoicePeriod(invoice)
    if (!price) throw new Error('Stripe charge invoice uses an unknown price')

    const amountMinor = nonNegativeInteger(object.amount)
    const currency = currencyCode(object.currency)
    if (amountMinor == null || !currency) {
      throw new Error('Stripe charge has invalid amount or currency')
    }

    return {
      action: 'apply',
      processor: 'charge',
      normalizedType: normalizedChargeType,
      profileId,
      plan: price.plan,
      billingPeriod: price.billingPeriod,
      amountMinor,
      currency,
      chargeId,
      customerId,
      invoiceId,
      chargedAt: toIsoFromUnix(object.created),
      periodStart: toIsoFromUnix(period.start),
      periodEnd: toIsoFromUnix(period.end),
    }
  }

  if (['refund.created', 'refund.updated', 'refund.failed'].includes(type)) {
    const normalizedType = normalizeStripeRefundStatus(object?.status)
    if (!normalizedType) {
      return {
        action: 'ignore', normalizedType: 'ignored', requiresProfile: false,
        note: 'refund_with_unknown_status_ignored',
      }
    }

    const refundId = object?.id?.toString()
    const chargeId = stripeRefundChargeId(object)
    const amountMinor = positiveInteger(object?.amount)
    const currency = currencyCode(object?.currency)
    if (!refundId || !chargeId || amountMinor == null || !currency) {
      throw new Error('Stripe refund is missing required ledger fields')
    }

    let profileId: string | null = null
    const customerId = stripeCustomerId(object)
    if (customerId) profileId = await profileForCustomer(admin, customerId)
    if (!profileId && stripeSecretKey) {
      const charge = await stripeGet(
        `/v1/charges/${encodeURIComponent(chargeId)}`,
        stripeSecretKey,
      )
      const chargeCustomerId = stripeCustomerId(charge)
      if (chargeCustomerId) {
        profileId = await profileForCustomer(admin, chargeCustomerId)
      }
    }

    const reasonCode = normalizeStripeRefundReason(object?.reason)
    const reasonDetail = refundReasonDetail(object)

    return {
      action: 'apply',
      processor: 'refund',
      normalizedType,
      requiresProfile: false,
      profileId,
      chargeId,
      refundId,
      amountMinor,
      currency,
      reasonCode,
      reasonDetail,
    }
  }

  return null
}

async function resolveProfile(
  admin: any,
  object: any,
  stripeSecretKey?: string,
) {
  const metadataProfile = profileIdFromMetadata(object)
  if (metadataProfile) return metadataProfile

  const customerId = stripeCustomerId(object)
  if (customerId) {
    const profileId = await profileForCustomer(admin, customerId)
    if (profileId) return profileId
  }

  const chargeId = stripeRefundChargeId(object)
  if (!chargeId || !stripeSecretKey) return null
  const charge = await stripeGet(
    `/v1/charges/${encodeURIComponent(chargeId)}`,
    stripeSecretKey,
  )
  const chargeCustomerId = stripeCustomerId(charge)
  return chargeCustomerId
    ? await profileForCustomer(admin, chargeCustomerId)
    : null
}

async function profileForCustomer(admin: any, customerId: string) {
  const { data, error } = await admin.rpc('billing_profile_for_provider_customer', {
    target_provider: STRIPE_PROVIDER,
    target_customer_id: customerId,
  })
  if (error) throw error
  return typeof data === 'string' && data ? data : null
}

async function findInvoicePaymentForPaymentIntent(
  stripeSecretKey: string,
  paymentIntentId: string,
) {
  const query = new URLSearchParams()
  query.set('payment[type]', 'payment_intent')
  query.set('payment[payment_intent]', paymentIntentId)
  query.set('limit', '1')
  const result = await stripeGet('/v1/invoice_payments', stripeSecretKey, query)
  return Array.isArray(result?.data) ? result.data[0] ?? null : null
}

async function stripeGet(
  path: string,
  stripeSecretKey: string,
  query?: URLSearchParams,
) {
  const url = new URL(`https://api.stripe.com${path}`)
  if (query) {
    for (const [key, value] of query.entries()) {
      url.searchParams.append(key, value)
    }
  }

  const response = await fetch(url, {
    method: 'GET',
    headers: { Authorization: `Bearer ${stripeSecretKey}` },
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) {
    throw new Error(`Stripe lookup failed with HTTP ${response.status}`)
  }
  return payload
}

function stripeEnv(): Record<string, string | undefined> {
  return {
    STRIPE_PRICE_PLUS_MONTHLY: Deno.env.get('STRIPE_PRICE_PLUS_MONTHLY'),
    STRIPE_PRICE_PLUS_ANNUAL: Deno.env.get('STRIPE_PRICE_PLUS_ANNUAL'),
    STRIPE_PRICE_PREMIUM_MONTHLY: Deno.env.get('STRIPE_PRICE_PREMIUM_MONTHLY'),
    STRIPE_PRICE_PREMIUM_ANNUAL: Deno.env.get('STRIPE_PRICE_PREMIUM_ANNUAL'),
  }
}

function nonNegativeInteger(value: unknown) {
  const number = Number(value)
  return Number.isSafeInteger(number) && number >= 0 ? number : null
}

function positiveInteger(value: unknown) {
  const number = Number(value)
  return Number.isSafeInteger(number) && number > 0 ? number : null
}

function currencyCode(value: unknown) {
  const normalized = typeof value === 'string' ? value.trim().toUpperCase() : ''
  return /^[A-Z]{3}$/.test(normalized) ? normalized : null
}

function refundReasonDetail(object: any) {
  const details = [object?.reason, object?.failure_reason]
    .filter((value) => typeof value === 'string' && value.trim() !== '')
    .map((value) => value.trim())
  return details.length ? details.join(': ').slice(0, 500) : null
}

function safeError(error: unknown) {
  return error instanceof Error ? error.message.slice(0, 500) : 'Unknown billing webhook error'
}
