-- Provider-independent billing audit foundation.
--
-- These tables deliberately live in the private schema and store only billing
-- references/state needed by Sharemarium. Raw card data and other payment
-- credentials must remain at the payment provider.

CREATE TABLE IF NOT EXISTS private.billing_webhook_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider TEXT NOT NULL CHECK (char_length(provider) BETWEEN 1 AND 64),
    provider_event_id TEXT NOT NULL CHECK (char_length(provider_event_id) BETWEEN 1 AND 255),
    event_type TEXT NOT NULL CHECK (char_length(event_type) BETWEEN 1 AND 120),
    profile_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    payload_sha256 TEXT CHECK (
        payload_sha256 IS NULL
        OR payload_sha256 ~ '^[0-9A-Fa-f]{64}$'
    ),
    status TEXT NOT NULL DEFAULT 'received' CHECK (
        status IN ('received', 'processing', 'processed', 'failed', 'ignored')
    ),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    provider_created_at TIMESTAMP WITH TIME ZONE,
    received_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    processing_started_at TIMESTAMP WITH TIME ZONE,
    processed_at TIMESTAMP WITH TIME ZONE,
    last_error TEXT CHECK (last_error IS NULL OR char_length(last_error) <= 4000),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT billing_webhook_events_provider_event_unique
        UNIQUE (provider, provider_event_id)
);

CREATE INDEX IF NOT EXISTS billing_webhook_events_profile_received_idx
    ON private.billing_webhook_events (profile_id, received_at DESC)
    WHERE profile_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS billing_webhook_events_status_received_idx
    ON private.billing_webhook_events (status, received_at)
    WHERE status IN ('received', 'processing', 'failed');

CREATE TABLE IF NOT EXISTS private.billing_charges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    webhook_event_id UUID REFERENCES private.billing_webhook_events(id) ON DELETE SET NULL,
    provider TEXT NOT NULL CHECK (char_length(provider) BETWEEN 1 AND 64),
    provider_customer_id TEXT CHECK (
        provider_customer_id IS NULL OR char_length(provider_customer_id) BETWEEN 1 AND 255
    ),
    provider_charge_id TEXT CHECK (
        provider_charge_id IS NULL OR char_length(provider_charge_id) BETWEEN 1 AND 255
    ),
    provider_invoice_id TEXT CHECK (
        provider_invoice_id IS NULL OR char_length(provider_invoice_id) BETWEEN 1 AND 255
    ),
    plan TEXT NOT NULL CHECK (plan IN ('plus', 'premium')),
    billing_period TEXT NOT NULL CHECK (billing_period IN ('monthly', 'annual')),
    amount_minor BIGINT NOT NULL CHECK (amount_minor >= 0),
    currency TEXT NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    status TEXT NOT NULL CHECK (
        status IN ('pending', 'paid', 'failed', 'partially_refunded', 'refunded', 'void')
    ),
    charged_at TIMESTAMP WITH TIME ZONE,
    period_start TIMESTAMP WITH TIME ZONE,
    period_end TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT billing_charges_period_order_check CHECK (
        period_start IS NULL
        OR period_end IS NULL
        OR period_end > period_start
    ),
    CONSTRAINT billing_charges_provider_charge_unique
        UNIQUE (provider, provider_charge_id)
);

CREATE INDEX IF NOT EXISTS billing_charges_profile_created_idx
    ON private.billing_charges (profile_id, created_at DESC)
    WHERE profile_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS billing_charges_provider_invoice_idx
    ON private.billing_charges (provider, provider_invoice_id)
    WHERE provider_invoice_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS private.billing_refunds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    charge_id UUID NOT NULL REFERENCES private.billing_charges(id) ON DELETE RESTRICT,
    webhook_event_id UUID REFERENCES private.billing_webhook_events(id) ON DELETE SET NULL,
    provider TEXT NOT NULL CHECK (char_length(provider) BETWEEN 1 AND 64),
    provider_refund_id TEXT CHECK (
        provider_refund_id IS NULL OR char_length(provider_refund_id) BETWEEN 1 AND 255
    ),
    amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
    currency TEXT NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    reason_code TEXT NOT NULL CHECK (
        reason_code IN (
            'duplicate_charge',
            'post_cancellation_charge',
            'fraud',
            'outage',
            'legal',
            'other'
        )
    ),
    reason_detail TEXT CHECK (
        reason_detail IS NULL OR char_length(reason_detail) <= 2000
    ),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (
        status IN ('pending', 'succeeded', 'failed', 'canceled')
    ),
    requested_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    completed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT billing_refunds_provider_refund_unique
        UNIQUE (provider, provider_refund_id)
);

CREATE INDEX IF NOT EXISTS billing_refunds_charge_requested_idx
    ON private.billing_refunds (charge_id, requested_at DESC);

-- Keep mutable audit rows timestamped consistently without requiring every
-- future provider adapter to remember to set updated_at.
CREATE OR REPLACE FUNCTION private.touch_billing_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.updated_at := timezone('utc'::text, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS billing_webhook_events_touch_updated_at
    ON private.billing_webhook_events;
CREATE TRIGGER billing_webhook_events_touch_updated_at
BEFORE UPDATE ON private.billing_webhook_events
FOR EACH ROW EXECUTE FUNCTION private.touch_billing_updated_at();

DROP TRIGGER IF EXISTS billing_charges_touch_updated_at
    ON private.billing_charges;
CREATE TRIGGER billing_charges_touch_updated_at
BEFORE UPDATE ON private.billing_charges
FOR EACH ROW EXECUTE FUNCTION private.touch_billing_updated_at();

DROP TRIGGER IF EXISTS billing_refunds_touch_updated_at
    ON private.billing_refunds;
CREATE TRIGGER billing_refunds_touch_updated_at
BEFORE UPDATE ON private.billing_refunds
FOR EACH ROW EXECUTE FUNCTION private.touch_billing_updated_at();

-- Reserve the charge row while validating active refunds so two concurrent
-- refund requests cannot together exceed the original charge amount.
CREATE OR REPLACE FUNCTION private.enforce_billing_refund_integrity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    charge_amount BIGINT;
    charge_currency TEXT;
    charge_provider TEXT;
    reserved_refunds BIGINT;
BEGIN
    SELECT charge.amount_minor, charge.currency, charge.provider
      INTO charge_amount, charge_currency, charge_provider
      FROM private.billing_charges AS charge
     WHERE charge.id = NEW.charge_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF NEW.provider <> charge_provider THEN
        RAISE EXCEPTION 'refund_provider_mismatch'
            USING ERRCODE = 'P0001';
    END IF;

    IF NEW.currency <> charge_currency THEN
        RAISE EXCEPTION 'refund_currency_mismatch'
            USING ERRCODE = 'P0001';
    END IF;

    IF NEW.status IN ('pending', 'succeeded') THEN
        SELECT COALESCE(sum(refund.amount_minor), 0)
          INTO reserved_refunds
          FROM private.billing_refunds AS refund
         WHERE refund.charge_id = NEW.charge_id
           AND refund.id <> NEW.id
           AND refund.status IN ('pending', 'succeeded');

        IF reserved_refunds + NEW.amount_minor > charge_amount THEN
            RAISE EXCEPTION 'refund_amount_exceeds_charge'
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS billing_refunds_integrity
    ON private.billing_refunds;
CREATE TRIGGER billing_refunds_integrity
BEFORE INSERT OR UPDATE OF charge_id, provider, amount_minor, currency, status
ON private.billing_refunds
FOR EACH ROW EXECUTE FUNCTION private.enforce_billing_refund_integrity();

REVOKE ALL ON TABLE private.billing_webhook_events
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.billing_charges
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.billing_refunds
    FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.billing_webhook_events
    TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.billing_charges
    TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.billing_refunds
    TO service_role;

REVOKE ALL ON FUNCTION private.touch_billing_updated_at()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.enforce_billing_refund_integrity()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.touch_billing_updated_at()
    TO service_role;
GRANT EXECUTE ON FUNCTION private.enforce_billing_refund_integrity()
    TO service_role;

COMMENT ON TABLE private.billing_webhook_events IS
    'Provider-independent webhook receipt ledger. Unique provider/event IDs are the database idempotency boundary.';
COMMENT ON TABLE private.billing_charges IS
    'Private billing history without raw card data; provider references may be attached after a payment provider is selected.';
COMMENT ON TABLE private.billing_refunds IS
    'Private refund history linked to a Sharemarium charge. Active refunds cannot exceed the original charge amount.';
