import { createClient } from 'npm:@supabase/supabase-js@2'
import {
  describeStripePrice,
  formBody,
  requireStripePrice,
  STRIPE_PROVIDER,
  stripeObjectId,
  subscriptionPeriodEnd,
  subscriptionPriceId,
  toIsoFromUnix,
} from '../_shared/stripe_billing.mjs'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) => Response.json(body, {
  status,
  headers: { ...corsHeaders, 'Cache-Control': 'no-store' },
})

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const authorization = request.headers.get('Authorization')
  const token = authorization?.replace(/^Bearer\s+/i, '')
  if (!token) return json({ error: 'Unauthorized' }, 401)

  const body = await request.json().catch(() => null)
  const targetPlan = body?.plan?.toString().trim().toLowerCase() ?? ''
  const requestId = body?.requestId?.toString().trim().toLowerCase() ?? ''
  if (!['plus', 'premium'].includes(targetPlan)) {
    return json({ error: 'Unsupported target plan' }, 400)
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(requestId)) {
    return json({ error: 'A valid plan change request ID is required' }, 400)
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY')
  if (!supabaseUrl || !serviceRoleKey || !stripeSecretKey) {
    return json({ error: 'Billing is not configured' }, 503)
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const { data: userData, error: userError } = await admin.auth.getUser(token)
  const user = userData.user
  if (userError || !user) return json({ error: 'Unauthorized' }, 401)

  const { data: contextRows, error: contextError } = await admin.rpc(
    'billing_provider_context',
    { target_profile: user.id, target_provider: STRIPE_PROVIDER },
  )
  if (contextError) return json({ error: 'Unable to load billing state' }, 500)
  const context = Array.isArray(contextRows) ? contextRows[0] : contextRows
  if (!context) return json({ error: 'Billing profile not found' }, 404)
  if (!['active', 'trialing'].includes(context.billing_status)) {
    return json({ error: 'Plan changes require an active subscription' }, 409)
  }
  if (context.effective_plan === targetPlan) {
    return json({ error: 'The selected plan is already active' }, 409)
  }

  const subscriptionId =
    typeof context.provider_subscription_id === 'string'
      ? context.provider_subscription_id.trim()
      : ''
  if (!subscriptionId) {
    return json({ error: 'No billing subscription was found' }, 409)
  }

  let scheduleId = ''
  try {
    const subscription = await stripeRequest(
      `/v1/subscriptions/${encodeURIComponent(subscriptionId)}`,
      stripeSecretKey,
      'GET',
    )
    const linkedCustomerId =
      typeof context.provider_customer_id === 'string'
        ? context.provider_customer_id.trim()
        : ''
    const stripeCustomerId = stripeObjectId(subscription?.customer)
    if (!linkedCustomerId || stripeCustomerId !== linkedCustomerId) {
      throw new Error('Stripe subscription customer does not match billing profile')
    }
    if (!['active', 'trialing'].includes(subscription?.status)) {
      return json({ error: 'Plan changes require an active subscription' }, 409)
    }
    if (subscription?.cancel_at_period_end === true) {
      return json({ error: 'Cancel the scheduled cancellation before changing plans' }, 409)
    }
    if (stripeObjectId(subscription?.schedule)) {
      return json({ error: 'A subscription change is already scheduled' }, 409)
    }

    const currentPrice = describeStripePrice(stripeEnv(), subscriptionPriceId(subscription))
    const periodEnd = subscriptionPeriodEnd(subscription)
    if (!currentPrice || !periodEnd) {
      throw new Error('Stripe subscription uses an unknown price or billing period')
    }
    if (currentPrice.plan === targetPlan) {
      return json({ error: 'The selected plan is already active' }, 409)
    }
    const targetPriceId = requireStripePrice(
      stripeEnv(),
      targetPlan,
      currentPrice.billingPeriod,
    )

    const schedule = await stripeRequest(
      '/v1/subscription_schedules',
      stripeSecretKey,
      'POST',
      formBody([['from_subscription', subscriptionId]]),
      `sharemarium-plan-change-create-${requestId}`,
    )
    scheduleId = schedule?.id?.toString() ?? ''
    if (!scheduleId) throw new Error('Stripe schedule response did not include an id')

    const phase = simpleCurrentPhase(schedule)
    const updateBody = scheduleUpdateBody({
      phase,
      targetPriceId,
      targetPlan,
      billingPeriod: currentPrice.billingPeriod,
      profileId: user.id,
      periodEnd,
    })

    const updated = await stripeRequest(
      `/v1/subscription_schedules/${encodeURIComponent(scheduleId)}`,
      stripeSecretKey,
      'POST',
      updateBody,
      `sharemarium-plan-change-update-${requestId}`,
    )
    const futurePhase = Array.isArray(updated?.phases) ? updated.phases[1] : null
    const effectiveAt = toIsoFromUnix(futurePhase?.start_date ?? periodEnd)
    if (!effectiveAt) throw new Error('Stripe schedule is missing its next phase start')

    return json({
      scheduledPlan: targetPlan,
      billingPeriod: currentPrice.billingPeriod,
      effectiveAt,
      scheduleId,
    })
  } catch (error) {
    if (scheduleId) {
      await releaseSchedule(scheduleId, stripeSecretKey, requestId)
    }
    console.error('Stripe plan change scheduling failed', safeError(error))
    return json({ error: 'Unable to schedule plan change' }, 502)
  }
})

function simpleCurrentPhase(schedule: any) {
  const phases = Array.isArray(schedule?.phases) ? schedule.phases : []
  const phase = phases[0]
  const items = Array.isArray(phase?.items) ? phase.items : []
  if (!phase || items.length !== 1 || !phase.start_date || !phase.end_date) {
    throw new Error('Only a simple one-item subscription can be changed automatically')
  }

  const item = items[0]
  const priceId = stripeObjectId(item?.price)
  const quantity = Number(item?.quantity ?? 1)
  const unsupported =
    (Array.isArray(phase.add_invoice_items) && phase.add_invoice_items.length > 0) ||
    (Array.isArray(phase.default_tax_rates) && phase.default_tax_rates.length > 0) ||
    (Array.isArray(phase.discounts) && phase.discounts.length > 0) ||
    (Array.isArray(item?.discounts) && item.discounts.length > 0) ||
    (Array.isArray(item?.tax_rates) && item.tax_rates.length > 0) ||
    phase.application_fee_percent != null ||
    phase.on_behalf_of != null ||
    phase.transfer_data != null

  if (!priceId || !Number.isInteger(quantity) || quantity !== 1 || unsupported) {
    throw new Error('Subscription has advanced billing settings that require manual review')
  }
  return phase
}

function scheduleUpdateBody({
  phase,
  targetPriceId,
  targetPlan,
  billingPeriod,
  profileId,
  periodEnd,
}: {
  phase: any
  targetPriceId: string
  targetPlan: string
  billingPeriod: string
  profileId: string
  periodEnd: number
}) {
  const currentItem = phase.items[0]
  const currentPriceId = stripeObjectId(currentItem?.price)
  const entries: Array<[string, unknown]> = [
    ['end_behavior', 'release'],
    ['proration_behavior', 'none'],
    ['metadata[sharemarium_profile_id]', profileId],
    ['metadata[sharemarium_target_plan]', targetPlan],
    ['metadata[sharemarium_effective_at]', String(periodEnd)],
    ['metadata[sharemarium_billing_period]', billingPeriod],
    ['phases[0][items][0][price]', currentPriceId],
    ['phases[0][items][0][quantity]', 1],
    ['phases[0][start_date]', phase.start_date],
    ['phases[0][end_date]', phase.end_date],
    ['phases[0][proration_behavior]', 'none'],
    ['phases[1][items][0][price]', targetPriceId],
    ['phases[1][items][0][quantity]', 1],
    ['phases[1][duration][interval]', billingPeriod === 'annual' ? 'year' : 'month'],
    ['phases[1][duration][interval_count]', 1],
    ['phases[1][proration_behavior]', 'none'],
  ]
  if (phase.trial_end) entries.push(['phases[0][trial_end]', phase.trial_end])

  const metadata = phase.metadata && typeof phase.metadata === 'object'
    ? phase.metadata
    : {}
  for (const [key, value] of Object.entries(metadata)) {
    if (/^[a-zA-Z0-9_.-]{1,40}$/.test(key) && typeof value === 'string') {
      entries.push([`phases[0][metadata][${key}]`, value])
    }
  }
  return formBody(entries)
}

async function releaseSchedule(
  scheduleId: string,
  secretKey: string,
  requestId: string,
) {
  try {
    await stripeRequest(
      `/v1/subscription_schedules/${encodeURIComponent(scheduleId)}/release`,
      secretKey,
      'POST',
      new URLSearchParams(),
      `sharemarium-plan-change-release-${requestId}`,
    )
  } catch (error) {
    console.error('Stripe schedule rollback failed', safeError(error))
  }
}

function stripeEnv(): Record<string, string | undefined> {
  return {
    STRIPE_PRICE_PLUS_MONTHLY: Deno.env.get('STRIPE_PRICE_PLUS_MONTHLY'),
    STRIPE_PRICE_PLUS_ANNUAL: Deno.env.get('STRIPE_PRICE_PLUS_ANNUAL'),
    STRIPE_PRICE_PREMIUM_MONTHLY: Deno.env.get('STRIPE_PRICE_PREMIUM_MONTHLY'),
    STRIPE_PRICE_PREMIUM_ANNUAL: Deno.env.get('STRIPE_PRICE_PREMIUM_ANNUAL'),
  }
}

async function stripeRequest(
  path: string,
  secretKey: string,
  method: 'GET' | 'POST',
  body?: URLSearchParams,
  idempotencyKey?: string,
) {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${secretKey}`,
  }
  if (body) headers['Content-Type'] = 'application/x-www-form-urlencoded'
  if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey

  const response = await fetch(`https://api.stripe.com${path}`, {
    method,
    headers,
    body,
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) {
    throw new Error(`Stripe request failed with HTTP ${response.status}`)
  }
  return payload
}

function safeError(error: unknown) {
  return error instanceof Error ? error.message.slice(0, 500) : 'Unknown billing plan change error'
}
