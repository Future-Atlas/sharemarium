-- Provider-independent normalized billing event processing.
--
-- A future payment-provider adapter is responsible only for:
--   1. verifying the provider signature,
--   2. mapping the provider payload to one normalized event type,
--   3. calling the service-role-only RPCs below.
--
-- Idempotency, stale-event protection, subscription state transitions, and
-- billing audit writes remain centralized in Postgres.

ALTER TABLE private.billing_webhook_events
    ADD COLUMN IF NOT EXISTS normalized_event_type TEXT,
    ADD COLUMN IF NOT EXISTS processing_note TEXT;

ALTER TABLE private.billing_webhook_events
    DROP CONSTRAINT IF EXISTS billing_webhook_events_normalized_event_type_check;
ALTER TABLE private.billing_webhook_events
    ADD CONSTRAINT billing_webhook_events_normalized_event_type_check
    CHECK (
        normalized_event_type IS NULL
        OR normalized_event_type IN (
            'subscription.trial_started',
            'subscription.active',
            'subscription.plan_change_scheduled',
            'subscription.cancel_scheduled',
            'subscription.payment_failed',
            'subscription.payment_recovered',
            'subscription.canceled',
            'subscription.trial_expired',
            'charge.pending',
            'charge.paid',
            'charge.failed',
            'charge.void',
            'refund.pending',
            'refund.succeeded',
            'refund.failed',
            'refund.canceled',
            'ignored'
        )
    );

ALTER TABLE private.billing_webhook_events
    DROP CONSTRAINT IF EXISTS billing_webhook_events_processing_note_length_check;
ALTER TABLE private.billing_webhook_events
    ADD CONSTRAINT billing_webhook_events_processing_note_length_check
    CHECK (processing_note IS NULL OR char_length(processing_note) <= 2000);

ALTER TABLE private.subscription_entitlements
    ADD COLUMN IF NOT EXISTS last_billing_event_id UUID
        REFERENCES private.billing_webhook_events(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS last_billing_event_order_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE private.billing_charges
    ADD COLUMN IF NOT EXISTS last_billing_event_order_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE private.billing_refunds
    ADD COLUMN IF NOT EXISTS last_billing_event_order_at TIMESTAMP WITH TIME ZONE;

COMMENT ON COLUMN private.billing_webhook_events.event_type IS
    'Raw provider event type after signature verification.';
COMMENT ON COLUMN private.billing_webhook_events.normalized_event_type IS
    'Provider-independent Sharemarium event type used by the normalized processors.';
COMMENT ON COLUMN private.subscription_entitlements.last_billing_event_order_at IS
    'Ordering timestamp of the most recent subscription lifecycle event applied to this entitlement.';

CREATE OR REPLACE FUNCTION public.claim_billing_webhook_event(
    incoming_provider TEXT,
    incoming_event_id TEXT,
    incoming_event_type TEXT,
    incoming_normalized_type TEXT,
    incoming_profile_id UUID DEFAULT NULL,
    incoming_payload_sha256 TEXT DEFAULT NULL,
    incoming_provider_created_at TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS TABLE (
    webhook_event_id UUID,
    should_process BOOLEAN,
    event_status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    event_row private.billing_webhook_events%ROWTYPE;
    now_utc TIMESTAMP WITH TIME ZONE := timezone('utc'::text, now());
BEGIN
    IF incoming_provider IS NULL OR char_length(btrim(incoming_provider)) NOT BETWEEN 1 AND 64 THEN
        RAISE EXCEPTION 'invalid_incoming_provider' USING ERRCODE = '22023';
    END IF;
    IF incoming_event_id IS NULL OR char_length(btrim(incoming_event_id)) NOT BETWEEN 1 AND 255 THEN
        RAISE EXCEPTION 'invalid_incoming_event_id' USING ERRCODE = '22023';
    END IF;
    IF incoming_event_type IS NULL OR char_length(btrim(incoming_event_type)) NOT BETWEEN 1 AND 120 THEN
        RAISE EXCEPTION 'invalid_incoming_event_type' USING ERRCODE = '22023';
    END IF;
    IF incoming_normalized_type IS NULL THEN
        RAISE EXCEPTION 'incoming_normalized_type_required' USING ERRCODE = '22023';
    END IF;
    IF incoming_payload_sha256 IS NOT NULL AND incoming_payload_sha256 !~ '^[0-9A-Fa-f]{64}$' THEN
        RAISE EXCEPTION 'invalid_incoming_payload_sha256' USING ERRCODE = '22023';
    END IF;

    INSERT INTO private.billing_webhook_events (
        provider,
        incoming_event_id,
        event_type,
        incoming_normalized_type,
        profile_id,
        incoming_payload_sha256,
        status,
        attempt_count,
        incoming_provider_created_at,
        processing_started_at,
        last_error,
        processing_note
    )
    VALUES (
        btrim(incoming_provider),
        btrim(incoming_event_id),
        btrim(incoming_event_type),
        incoming_normalized_type,
        incoming_profile_id,
        lower(incoming_payload_sha256),
        'processing',
        1,
        incoming_provider_created_at,
        now_utc,
        NULL,
        NULL
    )
    ON CONFLICT (provider, incoming_event_id) DO NOTHING
    RETURNING * INTO event_row;

    IF event_row.id IS NOT NULL THEN
        RETURN QUERY SELECT event_row.id, true, event_row.status;
        RETURN;
    END IF;

    SELECT event.*
      INTO event_row
      FROM private.billing_webhook_events AS event
     WHERE event.provider = btrim(incoming_provider)
       AND event.incoming_event_id = btrim(incoming_event_id)
     FOR UPDATE;

    IF event_row.event_type <> btrim(incoming_event_type)
       OR event_row.incoming_normalized_type IS DISTINCT FROM incoming_normalized_type
       OR (
            event_row.profile_id IS NOT NULL
            AND incoming_profile_id IS NOT NULL
            AND event_row.profile_id <> incoming_profile_id
       )
       OR (
            event_row.incoming_payload_sha256 IS NOT NULL
            AND incoming_payload_sha256 IS NOT NULL
            AND lower(event_row.incoming_payload_sha256) <> lower(incoming_payload_sha256)
       ) THEN
        RAISE EXCEPTION 'billing_event_identity_mismatch'
            USING ERRCODE = 'P0001';
    END IF;

    IF event_row.status IN ('processed', 'ignored') THEN
        RETURN QUERY SELECT event_row.id, false, event_row.status;
        RETURN;
    END IF;

    -- A concurrently executing delivery owns the event for 15 minutes. Failed,
    -- received, or stale processing rows are safe to reclaim and retry.
    IF event_row.status = 'processing'
       AND event_row.processing_started_at IS NOT NULL
       AND event_row.processing_started_at > now_utc - interval '15 minutes' THEN
        RETURN QUERY SELECT event_row.id, false, event_row.status;
        RETURN;
    END IF;

    UPDATE private.billing_webhook_events AS event
       SET incoming_normalized_type = COALESCE(event.incoming_normalized_type, incoming_normalized_type),
           profile_id = COALESCE(event.profile_id, incoming_profile_id),
           incoming_payload_sha256 = COALESCE(event.incoming_payload_sha256, lower(incoming_payload_sha256)),
           incoming_provider_created_at = COALESCE(event.incoming_provider_created_at, incoming_provider_created_at),
           status = 'processing',
           attempt_count = event.attempt_count + 1,
           processing_started_at = now_utc,
           processed_at = NULL,
           last_error = NULL,
           processing_note = NULL
     WHERE event.id = event_row.id
     RETURNING event.* INTO event_row;

    RETURN QUERY SELECT event_row.id, true, event_row.status;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_billing_webhook_event_failed(
    webhook_event_id UUID,
    error_detail TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    changed BOOLEAN;
BEGIN
    UPDATE private.billing_webhook_events AS event
       SET status = 'failed',
           last_error = left(COALESCE(NULLIF(btrim(error_detail), ''), 'unspecified_error'), 4000),
           processing_note = NULL
     WHERE event.id = webhook_event_id
       AND event.status IN ('received', 'processing', 'failed')
     RETURNING true INTO changed;
    RETURN COALESCE(changed, false);
END;
$$;

CREATE OR REPLACE FUNCTION public.ignore_billing_webhook_event(
    webhook_event_id UUID,
    note TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    changed BOOLEAN;
BEGIN
    UPDATE private.billing_webhook_events AS event
       SET status = 'ignored',
           processed_at = timezone('utc'::text, now()),
           last_error = NULL,
           processing_note = left(NULLIF(btrim(note), ''), 2000)
     WHERE event.id = webhook_event_id
       AND event.status = 'processing'
     RETURNING true INTO changed;
    RETURN COALESCE(changed, false);
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_normalized_subscription_event(
    webhook_event_id UUID,
    target_profile_id UUID,
    target_plan TEXT DEFAULT NULL,
    target_period_end TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    target_scheduled_plan TEXT DEFAULT NULL,
    target_scheduled_effective_at TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    target_payment_grace_until TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    target_provider_customer_id TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    event_row private.billing_webhook_events%ROWTYPE;
    entitlement private.subscription_entitlements%ROWTYPE;
    event_order_at TIMESTAMP WITH TIME ZONE;
    trial_end TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT event.*
      INTO event_row
      FROM private.billing_webhook_events AS event
     WHERE event.id = webhook_event_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'billing_event_not_found' USING ERRCODE = 'P0002';
    END IF;
    IF event_row.status IN ('processed', 'ignored') THEN
        RETURN false;
    END IF;
    IF event_row.status <> 'processing' THEN
        RAISE EXCEPTION 'billing_event_not_claimed' USING ERRCODE = '55000';
    END IF;
    IF event_row.normalized_event_type NOT LIKE 'subscription.%' THEN
        RAISE EXCEPTION 'billing_event_type_mismatch' USING ERRCODE = '22023';
    END IF;
    IF event_row.profile_id IS NOT NULL AND event_row.profile_id <> target_profile_id THEN
        RAISE EXCEPTION 'billing_event_profile_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = target_profile_id) THEN
        RAISE EXCEPTION 'billing_profile_not_found' USING ERRCODE = 'P0002';
    END IF;
    IF target_plan IS NOT NULL AND target_plan NOT IN ('plus', 'premium') THEN
        RAISE EXCEPTION 'invalid_paid_plan' USING ERRCODE = '22023';
    END IF;
    IF target_scheduled_plan IS NOT NULL
       AND target_scheduled_plan NOT IN ('free', 'plus', 'premium') THEN
        RAISE EXCEPTION 'invalid_scheduled_plan' USING ERRCODE = '22023';
    END IF;

    event_order_at := COALESCE(event_row.provider_created_at, event_row.received_at);

    INSERT INTO private.subscription_entitlements (profile_id, is_active, plan, billing_status)
    VALUES (target_profile_id, false, 'free', 'manual')
    ON CONFLICT (profile_id) DO NOTHING;

    SELECT subscription.*
      INTO entitlement
      FROM private.subscription_entitlements AS subscription
     WHERE subscription.profile_id = target_profile_id
     FOR UPDATE;

    IF entitlement.last_billing_event_order_at IS NOT NULL
       AND event_order_at < entitlement.last_billing_event_order_at THEN
        UPDATE private.billing_webhook_events
           SET status = 'ignored',
               processed_at = timezone('utc'::text, now()),
               last_error = NULL,
               processing_note = 'out_of_order_subscription_event'
         WHERE id = webhook_event_id;
        RETURN false;
    END IF;

    CASE event_row.normalized_event_type
        WHEN 'subscription.trial_started' THEN
            IF target_plan IS NULL THEN
                RAISE EXCEPTION 'target_plan_required' USING ERRCODE = '22023';
            END IF;
            IF entitlement.trial_used
               AND entitlement.last_billing_event_id IS DISTINCT FROM webhook_event_id THEN
                RAISE EXCEPTION 'subscription_trial_already_used' USING ERRCODE = 'P0001';
            END IF;
            trial_end := event_order_at + interval '10 days';
            UPDATE private.subscription_entitlements
               SET is_active = true,
                   plan = target_plan,
                   billing_status = 'trialing',
                   trial_used = true,
                   trial_ends_at = trial_end,
                   current_period_end = trial_end,
                   expires_at = trial_end,
                   payment_grace_until = NULL,
                   scheduled_plan = NULL,
                   scheduled_plan_effective_at = NULL,
                   cancel_at_period_end = false,
                   billing_provider = event_row.provider,
                   provider_customer_id = COALESCE(target_provider_customer_id, provider_customer_id),
                   granted_at = COALESCE(granted_at, event_order_at),
                   last_billing_event_id = webhook_event_id,
                   last_billing_event_order_at = event_order_at,
                   updated_at = timezone('utc'::text, now())
             WHERE profile_id = target_profile_id;

        WHEN 'subscription.active' THEN
            IF target_plan IS NULL OR target_period_end IS NULL THEN
                RAISE EXCEPTION 'active_subscription_state_incomplete' USING ERRCODE = '22023';
            END IF;
            IF target_period_end <= event_order_at THEN
                RAISE EXCEPTION 'subscription_period_end_must_be_future' USING ERRCODE = '22023';
            END IF;
            UPDATE private.subscription_entitlements
               SET is_active = true,
                   plan = target_plan,
                   billing_status = 'active',
                   current_period_end = target_period_end,
                   expires_at = target_period_end,
                   payment_grace_until = NULL,
                   trial_ends_at = NULL,
                   scheduled_plan = NULL,
                   scheduled_plan_effective_at = NULL,
                   cancel_at_period_end = false,
                   billing_provider = event_row.provider,
                   provider_customer_id = COALESCE(target_provider_customer_id, provider_customer_id),
                   granted_at = COALESCE(granted_at, event_order_at),
                   last_billing_event_id = webhook_event_id,
                   last_billing_event_order_at = event_order_at,
                   updated_at = timezone('utc'::text, now())
             WHERE profile_id = target_profile_id;

        WHEN 'subscription.plan_change_scheduled' THEN
            IF target_scheduled_plan IS NULL OR target_scheduled_effective_at IS NULL THEN
                RAISE EXCEPTION 'scheduled_plan_state_incomplete' USING ERRCODE = '22023';
            END IF;
            IF target_scheduled_effective_at <= event_order_at THEN
                RAISE EXCEPTION 'scheduled_plan_effective_at_must_be_future' USING ERRCODE = '22023';
            END IF;
            UPDATE private.subscription_entitlements
               SET scheduled_plan = target_scheduled_plan,
                   scheduled_plan_effective_at = target_scheduled_effective_at,
                   cancel_at_period_end = false,
                   billing_provider = event_row.provider,
                   provider_customer_id = COALESCE(target_provider_customer_id, provider_customer_id),
                   last_billing_event_id = webhook_event_id,
                   last_billing_event_order_at = event_order_at,
                   updated_at = timezone('utc'::text, now())
             WHERE profile_id = target_profile_id;

        WHEN 'subscription.cancel_scheduled' THEN
            UPDATE private.subscription_entitlements
               SET cancel_at_period_end = true,
                   scheduled_plan = NULL,
                   scheduled_plan_effective_at = NULL,
                   current_period_end = COALESCE(target_period_end, current_period_end),
                   expires_at = COALESCE(target_period_end, expires_at),
                   billing_provider = event_row.provider,
                   provider_customer_id = COALESCE(target_provider_customer_id, provider_customer_id),
                   last_billing_event_id = webhook_event_id,
                   last_billing_event_order_at = event_order_at,
                   updated_at = timezone('utc'::text, now())
             WHERE profile_id = target_profile_id;

        WHEN 'subscription.payment_failed' THEN
            IF target_payment_grace_until IS NULL
               OR target_payment_grace_until <= event_order_at THEN
                RAISE EXCEPTION 'valid_payment_grace_until_required' USING ERRCODE = '22023';
            END IF;
            UPDATE private.subscription_entitlements
               SET is_active = true,
                   billing_status = 'past_due',
                   payment_grace_until = target_payment_grace_until,
                   current_period_end = COALESCE(target_period_end, current_period_end),
                   expires_at = COALESCE(target_period_end, expires_at),
                   billing_provider = event_row.provider,
                   provider_customer_id = COALESCE(target_provider_customer_id, provider_customer_id),
                   last_billing_event_id = webhook_event_id,
                   last_billing_event_order_at = event_order_at,
                   updated_at = timezone('utc'::text, now())
             WHERE profile_id = target_profile_id;

        WHEN 'subscription.payment_recovered' THEN
            UPDATE private.subscription_entitlements
               SET is_active = true,
                   plan = COALESCE(target_plan, plan),
                   billing_status = 'active',
                   payment_grace_until = NULL,
                   current_period_end = COALESCE(target_period_end, current_period_end),
                   expires_at = COALESCE(target_period_end, expires_at),
                   billing_provider = event_row.provider,
                   provider_customer_id = COALESCE(target_provider_customer_id, provider_customer_id),
                   last_billing_event_id = webhook_event_id,
                   last_billing_event_order_at = event_order_at,
                   updated_at = timezone('utc'::text, now())
             WHERE profile_id = target_profile_id;

        WHEN 'subscription.canceled' THEN
            UPDATE private.subscription_entitlements
               SET is_active = false,
                   plan = 'free',
                   billing_status = 'canceled',
                   current_period_end = COALESCE(target_period_end, event_order_at),
                   expires_at = COALESCE(target_period_end, event_order_at),
                   payment_grace_until = NULL,
                   trial_ends_at = NULL,
                   scheduled_plan = NULL,
                   scheduled_plan_effective_at = NULL,
                   cancel_at_period_end = false,
                   billing_provider = event_row.provider,
                   provider_customer_id = COALESCE(target_provider_customer_id, provider_customer_id),
                   last_billing_event_id = webhook_event_id,
                   last_billing_event_order_at = event_order_at,
                   updated_at = timezone('utc'::text, now())
             WHERE profile_id = target_profile_id;

        WHEN 'subscription.trial_expired' THEN
            UPDATE private.subscription_entitlements
               SET is_active = false,
                   plan = 'free',
                   billing_status = 'canceled',
                   trial_used = true,
                   current_period_end = event_order_at,
                   expires_at = event_order_at,
                   payment_grace_until = NULL,
                   trial_ends_at = event_order_at,
                   scheduled_plan = NULL,
                   scheduled_plan_effective_at = NULL,
                   cancel_at_period_end = false,
                   billing_provider = event_row.provider,
                   provider_customer_id = COALESCE(target_provider_customer_id, provider_customer_id),
                   last_billing_event_id = webhook_event_id,
                   last_billing_event_order_at = event_order_at,
                   updated_at = timezone('utc'::text, now())
             WHERE profile_id = target_profile_id;

        ELSE
            RAISE EXCEPTION 'unsupported_normalized_subscription_event'
                USING ERRCODE = '22023';
    END CASE;

    UPDATE private.billing_webhook_events
       SET profile_id = COALESCE(profile_id, target_profile_id),
           status = 'processed',
           processed_at = timezone('utc'::text, now()),
           last_error = NULL,
           processing_note = 'subscription_state_applied'
     WHERE id = webhook_event_id;

    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_normalized_charge_event(
    webhook_event_id UUID,
    target_profile_id UUID,
    target_plan TEXT,
    target_billing_period TEXT,
    target_amount_minor BIGINT,
    target_currency TEXT,
    target_provider_charge_id TEXT,
    target_provider_customer_id TEXT DEFAULT NULL,
    target_provider_invoice_id TEXT DEFAULT NULL,
    target_charged_at TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    target_period_start TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    target_period_end TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    event_row private.billing_webhook_events%ROWTYPE;
    charge_row private.billing_charges%ROWTYPE;
    target_status TEXT;
    event_order_at TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT event.*
      INTO event_row
      FROM private.billing_webhook_events AS event
     WHERE event.id = webhook_event_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'billing_event_not_found' USING ERRCODE = 'P0002';
    END IF;
    IF event_row.status IN ('processed', 'ignored') THEN
        SELECT charge.* INTO charge_row
          FROM private.billing_charges AS charge
         WHERE charge.webhook_event_id = webhook_event_id
         LIMIT 1;
        RETURN charge_row.id;
    END IF;
    IF event_row.status <> 'processing' THEN
        RAISE EXCEPTION 'billing_event_not_claimed' USING ERRCODE = '55000';
    END IF;
    IF event_row.normalized_event_type NOT LIKE 'charge.%' THEN
        RAISE EXCEPTION 'billing_event_type_mismatch' USING ERRCODE = '22023';
    END IF;
    IF event_row.profile_id IS NOT NULL AND event_row.profile_id <> target_profile_id THEN
        RAISE EXCEPTION 'billing_event_profile_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF target_plan NOT IN ('plus', 'premium')
       OR target_billing_period NOT IN ('monthly', 'annual')
       OR target_amount_minor < 0
       OR upper(target_currency) !~ '^[A-Z]{3}$'
       OR target_provider_charge_id IS NULL
       OR char_length(btrim(target_provider_charge_id)) NOT BETWEEN 1 AND 255 THEN
        RAISE EXCEPTION 'invalid_normalized_charge' USING ERRCODE = '22023';
    END IF;

    target_status := CASE event_row.normalized_event_type
        WHEN 'charge.pending' THEN 'pending'
        WHEN 'charge.paid' THEN 'paid'
        WHEN 'charge.failed' THEN 'failed'
        WHEN 'charge.void' THEN 'void'
        ELSE NULL
    END;
    IF target_status IS NULL THEN
        RAISE EXCEPTION 'unsupported_normalized_charge_event' USING ERRCODE = '22023';
    END IF;
    event_order_at := COALESCE(event_row.provider_created_at, event_row.received_at);

    SELECT charge.*
      INTO charge_row
      FROM private.billing_charges AS charge
     WHERE charge.provider = event_row.provider
       AND charge.provider_charge_id = btrim(target_provider_charge_id)
     FOR UPDATE;

    IF FOUND THEN
        IF charge_row.last_billing_event_order_at IS NOT NULL
           AND event_order_at < charge_row.last_billing_event_order_at THEN
            UPDATE private.billing_webhook_events
               SET status = 'ignored',
                   processed_at = timezone('utc'::text, now()),
                   last_error = NULL,
                   processing_note = 'out_of_order_charge_event'
             WHERE id = webhook_event_id;
            RETURN charge_row.id;
        END IF;
        IF charge_row.profile_id IS NOT NULL AND charge_row.profile_id <> target_profile_id THEN
            RAISE EXCEPTION 'billing_charge_profile_mismatch' USING ERRCODE = 'P0001';
        END IF;
        IF charge_row.plan <> target_plan
           OR charge_row.billing_period <> target_billing_period
           OR charge_row.amount_minor <> target_amount_minor
           OR charge_row.currency <> upper(target_currency) THEN
            RAISE EXCEPTION 'billing_charge_identity_mismatch' USING ERRCODE = 'P0001';
        END IF;

        UPDATE private.billing_charges AS charge
           SET profile_id = COALESCE(charge.profile_id, target_profile_id),
               webhook_event_id = webhook_event_id,
               provider_customer_id = COALESCE(target_provider_customer_id, charge.provider_customer_id),
               provider_invoice_id = COALESCE(target_provider_invoice_id, charge.provider_invoice_id),
               status = target_status,
               charged_at = COALESCE(target_charged_at, charge.charged_at),
               period_start = COALESCE(target_period_start, charge.period_start),
               period_end = COALESCE(target_period_end, charge.period_end),
               last_billing_event_order_at = event_order_at
         WHERE charge.id = charge_row.id
         RETURNING charge.* INTO charge_row;
    ELSE
        INSERT INTO private.billing_charges (
            profile_id,
            webhook_event_id,
            provider,
            provider_customer_id,
            provider_charge_id,
            provider_invoice_id,
            plan,
            billing_period,
            amount_minor,
            currency,
            status,
            charged_at,
            period_start,
            period_end,
            last_billing_event_order_at
        )
        VALUES (
            target_profile_id,
            webhook_event_id,
            event_row.provider,
            target_provider_customer_id,
            btrim(target_provider_charge_id),
            target_provider_invoice_id,
            target_plan,
            target_billing_period,
            target_amount_minor,
            upper(target_currency),
            target_status,
            target_charged_at,
            target_period_start,
            target_period_end,
            event_order_at
        )
        RETURNING * INTO charge_row;
    END IF;

    UPDATE private.billing_webhook_events
       SET profile_id = COALESCE(profile_id, target_profile_id),
           status = 'processed',
           processed_at = timezone('utc'::text, now()),
           last_error = NULL,
           processing_note = 'charge_state_applied'
     WHERE id = webhook_event_id;

    RETURN charge_row.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_normalized_refund_event(
    webhook_event_id UUID,
    target_provider_charge_id TEXT,
    target_provider_refund_id TEXT,
    target_amount_minor BIGINT,
    target_currency TEXT,
    target_reason_code TEXT,
    target_reason_detail TEXT DEFAULT NULL,
    target_completed_at TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    event_row private.billing_webhook_events%ROWTYPE;
    charge_row private.billing_charges%ROWTYPE;
    refund_row private.billing_refunds%ROWTYPE;
    target_status TEXT;
    succeeded_total BIGINT;
    event_order_at TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT event.*
      INTO event_row
      FROM private.billing_webhook_events AS event
     WHERE event.id = webhook_event_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'billing_event_not_found' USING ERRCODE = 'P0002';
    END IF;
    IF event_row.status IN ('processed', 'ignored') THEN
        SELECT refund.* INTO refund_row
          FROM private.billing_refunds AS refund
         WHERE refund.webhook_event_id = webhook_event_id
         LIMIT 1;
        RETURN refund_row.id;
    END IF;
    IF event_row.status <> 'processing' THEN
        RAISE EXCEPTION 'billing_event_not_claimed' USING ERRCODE = '55000';
    END IF;
    IF event_row.normalized_event_type NOT LIKE 'refund.%' THEN
        RAISE EXCEPTION 'billing_event_type_mismatch' USING ERRCODE = '22023';
    END IF;
    IF target_provider_charge_id IS NULL
       OR char_length(btrim(target_provider_charge_id)) NOT BETWEEN 1 AND 255
       OR target_provider_refund_id IS NULL
       OR char_length(btrim(target_provider_refund_id)) NOT BETWEEN 1 AND 255
       OR target_amount_minor <= 0
       OR upper(target_currency) !~ '^[A-Z]{3}$'
       OR target_reason_code NOT IN (
            'duplicate_charge', 'post_cancellation_charge', 'fraud',
            'outage', 'legal', 'other'
       ) THEN
        RAISE EXCEPTION 'invalid_normalized_refund' USING ERRCODE = '22023';
    END IF;

    target_status := CASE event_row.normalized_event_type
        WHEN 'refund.pending' THEN 'pending'
        WHEN 'refund.succeeded' THEN 'succeeded'
        WHEN 'refund.failed' THEN 'failed'
        WHEN 'refund.canceled' THEN 'canceled'
        ELSE NULL
    END;
    IF target_status IS NULL THEN
        RAISE EXCEPTION 'unsupported_normalized_refund_event' USING ERRCODE = '22023';
    END IF;
    event_order_at := COALESCE(event_row.provider_created_at, event_row.received_at);

    SELECT charge.*
      INTO charge_row
      FROM private.billing_charges AS charge
     WHERE charge.provider = event_row.provider
       AND charge.provider_charge_id = btrim(target_provider_charge_id)
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'billing_charge_not_found' USING ERRCODE = 'P0002';
    END IF;
    IF event_row.profile_id IS NOT NULL
       AND charge_row.profile_id IS NOT NULL
       AND event_row.profile_id <> charge_row.profile_id THEN
        RAISE EXCEPTION 'billing_event_profile_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF charge_row.currency <> upper(target_currency) THEN
        RAISE EXCEPTION 'refund_currency_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF charge_row.status IN ('failed', 'void', 'pending') THEN
        RAISE EXCEPTION 'charge_is_not_refundable' USING ERRCODE = 'P0001';
    END IF;

    SELECT refund.*
      INTO refund_row
      FROM private.billing_refunds AS refund
     WHERE refund.provider = event_row.provider
       AND refund.provider_refund_id = btrim(target_provider_refund_id)
     FOR UPDATE;

    IF FOUND THEN
        IF refund_row.last_billing_event_order_at IS NOT NULL
           AND event_order_at < refund_row.last_billing_event_order_at THEN
            UPDATE private.billing_webhook_events
               SET status = 'ignored',
                   processed_at = timezone('utc'::text, now()),
                   last_error = NULL,
                   processing_note = 'out_of_order_refund_event'
             WHERE id = webhook_event_id;
            RETURN refund_row.id;
        END IF;
        IF refund_row.charge_id <> charge_row.id
           OR refund_row.amount_minor <> target_amount_minor
           OR refund_row.currency <> upper(target_currency) THEN
            RAISE EXCEPTION 'billing_refund_identity_mismatch' USING ERRCODE = 'P0001';
        END IF;
        UPDATE private.billing_refunds AS refund
           SET webhook_event_id = webhook_event_id,
               reason_code = target_reason_code,
               reason_detail = COALESCE(target_reason_detail, refund.reason_detail),
               status = target_status,
               completed_at = CASE
                    WHEN target_status = 'succeeded'
                        THEN COALESCE(target_completed_at, refund.completed_at, timezone('utc'::text, now()))
                    ELSE target_completed_at
               END,
               last_billing_event_order_at = event_order_at
         WHERE refund.id = refund_row.id
         RETURNING refund.* INTO refund_row;
    ELSE
        INSERT INTO private.billing_refunds (
            charge_id,
            webhook_event_id,
            provider,
            provider_refund_id,
            amount_minor,
            currency,
            reason_code,
            reason_detail,
            status,
            completed_at,
            last_billing_event_order_at
        )
        VALUES (
            charge_row.id,
            webhook_event_id,
            event_row.provider,
            btrim(target_provider_refund_id),
            target_amount_minor,
            upper(target_currency),
            target_reason_code,
            target_reason_detail,
            target_status,
            CASE
                WHEN target_status = 'succeeded'
                    THEN COALESCE(target_completed_at, timezone('utc'::text, now()))
                ELSE target_completed_at
            END,
            event_order_at
        )
        RETURNING * INTO refund_row;
    END IF;

    SELECT COALESCE(sum(refund.amount_minor), 0)
      INTO succeeded_total
      FROM private.billing_refunds AS refund
     WHERE refund.charge_id = charge_row.id
       AND refund.status = 'succeeded';

    UPDATE private.billing_charges AS charge
       SET status = CASE
            WHEN succeeded_total >= charge.amount_minor THEN 'refunded'
            WHEN succeeded_total > 0 THEN 'partially_refunded'
            ELSE 'paid'
       END
     WHERE charge.id = charge_row.id;

    UPDATE private.billing_webhook_events
       SET profile_id = COALESCE(profile_id, charge_row.profile_id),
           status = 'processed',
           processed_at = timezone('utc'::text, now()),
           last_error = NULL,
           processing_note = 'refund_state_applied'
     WHERE id = webhook_event_id;

    RETURN refund_row.id;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_billing_webhook_event(TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TIMESTAMP WITH TIME ZONE)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_billing_webhook_event_failed(UUID, TEXT)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ignore_billing_webhook_event(UUID, TEXT)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_normalized_subscription_event(UUID, UUID, TEXT, TIMESTAMP WITH TIME ZONE, TEXT, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE, TEXT)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_normalized_charge_event(UUID, UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_normalized_refund_event(UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TIMESTAMP WITH TIME ZONE)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.claim_billing_webhook_event(TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TIMESTAMP WITH TIME ZONE)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_billing_webhook_event_failed(UUID, TEXT)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.ignore_billing_webhook_event(UUID, TEXT)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_normalized_subscription_event(UUID, UUID, TEXT, TIMESTAMP WITH TIME ZONE, TEXT, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE, TEXT)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_normalized_charge_event(UUID, UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_normalized_refund_event(UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TIMESTAMP WITH TIME ZONE)
    TO service_role;

COMMENT ON FUNCTION public.claim_billing_webhook_event(TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TIMESTAMP WITH TIME ZONE) IS
    'Service-role-only idempotency boundary called after provider signature verification. Reclaims failed or stale events and rejects identity mismatches.';
COMMENT ON FUNCTION public.apply_normalized_subscription_event(UUID, UUID, TEXT, TIMESTAMP WITH TIME ZONE, TEXT, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE, TEXT) IS
    'Applies one provider-independent subscription lifecycle event and ignores events older than the latest applied subscription event.';
COMMENT ON FUNCTION public.apply_normalized_charge_event(UUID, UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE) IS
    'Upserts an immutable-identity billing charge from a claimed normalized charge event.';
COMMENT ON FUNCTION public.apply_normalized_refund_event(UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, TIMESTAMP WITH TIME ZONE) IS
    'Upserts a normalized refund and reconciles the parent charge refund status.';
