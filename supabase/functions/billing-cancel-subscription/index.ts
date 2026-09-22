import { createClient } from 'npm:@supabase/supabase-js@2'

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
    { target_profile: user.id, target_provider: 'stripe' },
  )
  if (contextError) return json({ error: 'Unable to load billing state' }, 500)

  const context = Array.isArray(contextRows) ? contextRows[0] : contextRows
  const subscriptionId =
    typeof context?.provider_subscription_id === 'string'
      ? context.provider_subscription_id.trim()
      : ''
  if (!subscriptionId) {
    return json({ error: 'No active billing subscription was found' }, 409)
  }

  try {
    const subscription = await stripeRequest(
      `/v1/subscriptions/${encodeURIComponent(subscriptionId)}`,
      stripeSecretKey,
      'GET',
    )

    const linkedCustomerId =
      typeof context?.provider_customer_id === 'string'
        ? context.provider_customer_id.trim()
        : ''
    const stripeCustomerId = typeof subscription?.customer === 'string'
      ? subscription.customer
      : subscription?.customer?.id
    if (linkedCustomerId && stripeCustomerId !== linkedCustomerId) {
      throw new Error('Stripe subscription customer does not match billing profile')
    }

    if (subscription?.status === 'canceled') {
      return json({ mode: 'already_canceled', effectiveAt: null })
    }

    if (subscription?.cancel_at_period_end === true) {
      return json({
        mode: 'already_scheduled',
        effectiveAt: toIsoFromUnix(subscription?.current_period_end),
      })
    }

    if (subscription?.status === 'trialing') {
      const canceled = await stripeRequest(
        `/v1/subscriptions/${encodeURIComponent(subscriptionId)}`,
        stripeSecretKey,
        'DELETE',
      )
      if (canceled?.status !== 'canceled') {
        throw new Error('Stripe trial cancellation did not reach canceled state')
      }
      return json({ mode: 'immediate', effectiveAt: null })
    }

    const body = new URLSearchParams()
    body.set('cancel_at_period_end', 'true')
    const updated = await stripeRequest(
      `/v1/subscriptions/${encodeURIComponent(subscriptionId)}`,
      stripeSecretKey,
      'POST',
      body,
    )
    if (updated?.cancel_at_period_end !== true) {
      throw new Error('Stripe subscription cancellation was not scheduled')
    }

    return json({
      mode: 'period_end',
      effectiveAt: toIsoFromUnix(updated?.current_period_end),
    })
  } catch (error) {
    console.error('Stripe subscription cancellation failed', safeError(error))
    return json({ error: 'Unable to cancel subscription' }, 502)
  }
})

async function stripeRequest(
  path: string,
  secretKey: string,
  method: 'GET' | 'POST' | 'DELETE',
  body?: URLSearchParams,
) {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${secretKey}`,
  }
  if (body) headers['Content-Type'] = 'application/x-www-form-urlencoded'

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

function toIsoFromUnix(value: unknown) {
  const unix = Number(value)
  return Number.isFinite(unix) && unix > 0
    ? new Date(Math.trunc(unix) * 1000).toISOString()
    : null
}

function safeError(error: unknown) {
  return error instanceof Error ? error.message.slice(0, 500) : 'Unknown billing cancellation error'
}
