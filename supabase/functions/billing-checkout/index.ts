import { createClient } from 'npm:@supabase/supabase-js@2'
import {
  formBody,
  requireStripePrice,
  STRIPE_PROVIDER,
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

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY')
  const appUrlRaw = Deno.env.get('BILLING_APP_URL')
  if (!supabaseUrl || !serviceRoleKey || !stripeSecretKey || !appUrlRaw) {
    return json({ error: 'Billing is not configured' }, 503)
  }

  let appUrl: URL
  try {
    appUrl = new URL(appUrlRaw)
    if (appUrl.protocol !== 'https:' && appUrl.hostname !== 'localhost') {
      throw new Error('Billing app URL must use HTTPS')
    }
  } catch {
    return json({ error: 'Billing is not configured' }, 503)
  }

  const body = await request.json().catch(() => null)
  const plan = body?.plan?.toString().toLowerCase()
  const billingPeriod = body?.billingPeriod?.toString().toLowerCase()
  let priceId: string
  try {
    priceId = requireStripePrice(stripeEnv(), plan, billingPeriod)
  } catch {
    return json({ error: 'Unsupported billing selection' }, 400)
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
  if (context.effective_plan !== 'free' || ['trialing', 'active', 'past_due'].includes(context.billing_status)) {
    return json({ error: 'An active subscription already exists' }, 409)
  }

  let customerId = context.provider_customer_id?.toString() || null
  try {
    if (!customerId) {
      const customer = await stripeRequest('/v1/customers', stripeSecretKey, formBody([
        ['email', user.email],
        ['metadata[sharemarium_profile_id]', user.id],
      ]), `sharemarium-customer-${user.id}`)
      customerId = customer.id
      if (!customerId) throw new Error('Stripe customer response did not include an id')
      const { error: linkError } = await admin.rpc('link_billing_provider_identity', {
        target_profile: user.id,
        target_provider: STRIPE_PROVIDER,
        target_customer_id: customerId,
        target_subscription_id: null,
      })
      if (linkError) throw linkError
    }

    const trialUsed = context.trial_used === true
    const successUrl = new URL(appUrl)
    successUrl.searchParams.set('billing_checkout', 'success')
    successUrl.searchParams.set('session_id', '{CHECKOUT_SESSION_ID}')
    const cancelUrl = new URL(appUrl)
    cancelUrl.searchParams.set('billing_checkout', 'canceled')

    const entries: Array<[string, unknown]> = [
      ['mode', 'subscription'],
      ['customer', customerId],
      ['client_reference_id', user.id],
      ['line_items[0][price]', priceId],
      ['line_items[0][quantity]', 1],
      ['success_url', successUrl.toString()],
      ['cancel_url', cancelUrl.toString()],
      ['metadata[sharemarium_profile_id]', user.id],
      ['metadata[sharemarium_plan]', plan],
      ['metadata[sharemarium_billing_period]', billingPeriod],
      ['subscription_data[metadata][sharemarium_profile_id]', user.id],
      ['subscription_data[metadata][sharemarium_plan]', plan],
      ['subscription_data[metadata][sharemarium_billing_period]', billingPeriod],
    ]
    if (!trialUsed) entries.push(['subscription_data[trial_period_days]', 10])

    const session = await stripeRequest(
      '/v1/checkout/sessions',
      stripeSecretKey,
      formBody(entries),
      `sharemarium-checkout-${user.id}-${plan}-${billingPeriod}-${trialUsed ? 'paid' : 'trial'}`,
    )
    if (!session.url || !session.id) throw new Error('Stripe Checkout response is incomplete')
    return json({ checkoutUrl: session.url, sessionId: session.id, trialDays: trialUsed ? 0 : 10 })
  } catch (error) {
    console.error('Stripe Checkout creation failed', safeError(error))
    return json({ error: 'Unable to start billing checkout' }, 502)
  }
})

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
  body: URLSearchParams,
  idempotencyKey?: string,
) {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${secretKey}`,
    'Content-Type': 'application/x-www-form-urlencoded',
  }
  if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey
  const response = await fetch(`https://api.stripe.com${path}`, {
    method: 'POST',
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
  return error instanceof Error ? error.message.slice(0, 500) : 'Unknown billing error'
}
