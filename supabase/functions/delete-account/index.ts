import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (request.method !== 'POST') {
    return Response.json(
      { error: 'Method not allowed' },
      { status: 405, headers: corsHeaders },
    )
  }

  const body = await request.json().catch(() => null)
  if (body?.confirmation !== true) {
    return Response.json(
      { error: 'Explicit confirmation is required' },
      { status: 400, headers: corsHeaders },
    )
  }

  const authorization = request.headers.get('Authorization')
  const token = authorization?.replace(/^Bearer\s+/i, '')
  if (!token) {
    return Response.json(
      { error: 'Unauthorized' },
      { status: 401, headers: corsHeaders },
    )
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceRoleKey) {
    return Response.json(
      { error: 'Server configuration is incomplete' },
      { status: 500, headers: corsHeaders },
    )
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const { data: userData, error: userError } = await admin.auth.getUser(token)
  if (userError || !userData.user) {
    return Response.json(
      { error: 'Unauthorized' },
      { status: 401, headers: corsHeaders },
    )
  }

  const profileId = userData.user.id
  const { data: billingRows, error: billingError } = await admin.rpc(
    'billing_provider_context',
    { target_profile: profileId, target_provider: 'stripe' },
  )
  if (billingError) {
    return Response.json(
      { error: 'Unable to verify billing state' },
      { status: 500, headers: corsHeaders },
    )
  }
  const billingContext = Array.isArray(billingRows) ? billingRows[0] : billingRows
  const providerSubscriptionId =
    typeof billingContext?.provider_subscription_id === 'string'
      ? billingContext.provider_subscription_id.trim()
      : ''

  // Resolve the provider subscription before deletion preparation. The profile
  // and its private billing entitlement can disappear as part of account
  // deletion, so the provider identity must be known before Auth deletion.
  const { error: prepareError } = await admin.rpc(
    'prepare_self_account_deletion',
    { target_profile: profileId },
  )
  if (prepareError) {
    return Response.json(
      { error: prepareError.message },
      { status: 500, headers: corsHeaders },
    )
  }

  const { data: auditId, error: auditError } = await admin.rpc(
    'prepare_deleted_account_record',
    {
      target_profile: profileId,
      deletion_kind: 'self',
      deleting_admin: null,
      deletion_notes: 'User-requested account withdrawal',
    },
  )
  if (auditError || !auditId) {
    await admin.rpc('cancel_self_account_deletion', {
      target_profile: profileId,
    })
    return Response.json(
      { error: auditError?.message ?? 'Unable to record account deletion' },
      { status: 500, headers: corsHeaders },
    )
  }

  if (providerSubscriptionId) {
    const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeSecretKey) {
      await rollbackDeletionPreparation(
        admin,
        profileId,
        auditId,
        'Billing cancellation is not configured',
      )
      return Response.json(
        { error: 'Unable to cancel the active subscription before account deletion' },
        { status: 503, headers: corsHeaders },
      )
    }

    try {
      await cancelStripeSubscription({
        subscriptionId: providerSubscriptionId,
        secretKey: stripeSecretKey,
      })
    } catch (error) {
      await rollbackDeletionPreparation(
        admin,
        profileId,
        auditId,
        safeError(error),
      )
      return Response.json(
        { error: 'Unable to cancel the active subscription before account deletion' },
        { status: 502, headers: corsHeaders },
      )
    }
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(profileId)
  if (deleteError) {
    await admin.rpc('cancel_self_account_deletion', {
      target_profile: profileId,
    })
    await admin.rpc('finalize_deleted_account_record', {
      audit_record: auditId,
      succeeded: false,
      failure_message: deleteError.message,
    })
    return Response.json(
      { error: deleteError.message },
      { status: 500, headers: corsHeaders },
    )
  }

  await admin.rpc('finalize_deleted_account_record', {
    audit_record: auditId,
    succeeded: true,
    failure_message: null,
  })

  return Response.json({ deleted: true }, { headers: corsHeaders })
})

async function cancelStripeSubscription({
  subscriptionId,
  secretKey,
}: {
  subscriptionId: string
  secretKey: string
}) {
  const subscriptionPath =
    `https://api.stripe.com/v1/subscriptions/${encodeURIComponent(subscriptionId)}`
  const authorization = { Authorization: `Bearer ${secretKey}` }

  // Confirm that the stored subscription exists in the Stripe account selected
  // by this secret. A 404 is not treated as safe because it can also indicate
  // a test/live or account mismatch while the real subscription still bills.
  const lookupResponse = await fetch(subscriptionPath, {
    method: 'GET',
    headers: authorization,
  })
  const lookupPayload = await lookupResponse.json().catch(() => ({}))
  if (!lookupResponse.ok) {
    throw new Error(
      `Stripe subscription lookup failed with HTTP ${lookupResponse.status}`,
    )
  }
  if (lookupPayload?.status === 'canceled') return

  const cancelResponse = await fetch(subscriptionPath, {
    method: 'DELETE',
    headers: authorization,
  })
  const cancelPayload = await cancelResponse.json().catch(() => ({}))
  if (!cancelResponse.ok || cancelPayload?.status !== 'canceled') {
    throw new Error(
      `Stripe subscription cancellation failed with HTTP ${cancelResponse.status}`,
    )
  }
}

async function rollbackDeletionPreparation(
  admin: any,
  profileId: string,
  auditId: string,
  failureMessage: string,
) {
  await admin.rpc('cancel_self_account_deletion', {
    target_profile: profileId,
  })
  await admin.rpc('finalize_deleted_account_record', {
    audit_record: auditId,
    succeeded: false,
    failure_message: failureMessage.slice(0, 1000),
  })
}

function safeError(error: unknown) {
  return error instanceof Error ? error.message.slice(0, 500) : 'Unknown billing cancellation error'
}
