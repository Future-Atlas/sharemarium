-- Stripe-specific identity linking kept separate from provider-independent
-- subscription lifecycle state. These helpers are service-role only and do not
-- grant paid access by themselves.

ALTER TABLE private.subscription_entitlements
    ADD COLUMN IF NOT EXISTS provider_subscription_id TEXT;

ALTER TABLE private.subscription_entitlements
    DROP CONSTRAINT IF EXISTS subscription_entitlements_provider_subscription_length_check;
ALTER TABLE private.subscription_entitlements
    ADD CONSTRAINT subscription_entitlements_provider_subscription_length_check
    CHECK (
        provider_subscription_id IS NULL
        OR char_length(provider_subscription_id) BETWEEN 1 AND 255
    );

CREATE UNIQUE INDEX IF NOT EXISTS subscription_entitlements_provider_subscription_uidx
    ON private.subscription_entitlements (billing_provider, provider_subscription_id)
    WHERE billing_provider IS NOT NULL AND provider_subscription_id IS NOT NULL;

COMMENT ON COLUMN private.subscription_entitlements.provider_subscription_id IS
    'Provider subscription identifier. Linking this identifier alone never grants paid access.';

CREATE OR REPLACE FUNCTION public.billing_provider_context(
    target_profile UUID,
    target_provider TEXT
)
RETURNS TABLE (
    provider_customer_id TEXT,
    provider_subscription_id TEXT,
    trial_used BOOLEAN,
    effective_plan TEXT,
    billing_status TEXT,
    current_period_end TIMESTAMP WITH TIME ZONE
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        entitlement.provider_customer_id,
        entitlement.provider_subscription_id,
        COALESCE(entitlement.trial_used, false),
        private.profile_effective_subscription_plan(target_profile),
        COALESCE(entitlement.billing_status, 'manual'),
        entitlement.current_period_end
    FROM (SELECT 1) AS singleton
    LEFT JOIN private.subscription_entitlements AS entitlement
      ON entitlement.profile_id = target_profile
     AND (
          entitlement.billing_provider IS NULL
          OR entitlement.billing_provider = btrim(target_provider)
     )
    WHERE EXISTS (
        SELECT 1 FROM public.profiles AS profile WHERE profile.id = target_profile
    );
$$;

CREATE OR REPLACE FUNCTION public.link_billing_provider_identity(
    target_profile UUID,
    target_provider TEXT,
    target_customer_id TEXT,
    target_subscription_id TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF target_provider IS NULL
       OR char_length(btrim(target_provider)) NOT BETWEEN 1 AND 64
       OR target_customer_id IS NULL
       OR char_length(btrim(target_customer_id)) NOT BETWEEN 1 AND 255
       OR (
            target_subscription_id IS NOT NULL
            AND char_length(btrim(target_subscription_id)) NOT BETWEEN 1 AND 255
       ) THEN
        RAISE EXCEPTION 'invalid_billing_provider_identity' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.profiles AS profile WHERE profile.id = target_profile
    ) THEN
        RAISE EXCEPTION 'billing_profile_not_found' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO private.subscription_entitlements (
        profile_id,
        is_active,
        plan,
        billing_status,
        billing_provider,
        provider_customer_id,
        provider_subscription_id,
        updated_at
    )
    VALUES (
        target_profile,
        false,
        'free',
        'manual',
        btrim(target_provider),
        btrim(target_customer_id),
        NULLIF(btrim(target_subscription_id), ''),
        timezone('utc'::text, now())
    )
    ON CONFLICT (profile_id) DO UPDATE
       SET billing_provider = EXCLUDED.billing_provider,
           provider_customer_id = EXCLUDED.provider_customer_id,
           provider_subscription_id = COALESCE(
               EXCLUDED.provider_subscription_id,
               private.subscription_entitlements.provider_subscription_id
           ),
           updated_at = timezone('utc'::text, now())
     WHERE private.subscription_entitlements.billing_provider IS NULL
        OR private.subscription_entitlements.billing_provider = EXCLUDED.billing_provider;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'billing_provider_mismatch' USING ERRCODE = 'P0001';
    END IF;

    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.billing_profile_for_provider_customer(
    target_provider TEXT,
    target_customer_id TEXT
)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT entitlement.profile_id
    FROM private.subscription_entitlements AS entitlement
    WHERE entitlement.billing_provider = btrim(target_provider)
      AND entitlement.provider_customer_id = btrim(target_customer_id)
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.billing_profile_for_provider_subscription(
    target_provider TEXT,
    target_subscription_id TEXT
)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT entitlement.profile_id
    FROM private.subscription_entitlements AS entitlement
    WHERE entitlement.billing_provider = btrim(target_provider)
      AND entitlement.provider_subscription_id = btrim(target_subscription_id)
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.billing_provider_context(UUID, TEXT)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.link_billing_provider_identity(UUID, TEXT, TEXT, TEXT)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.billing_profile_for_provider_customer(TEXT, TEXT)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.billing_profile_for_provider_subscription(TEXT, TEXT)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.billing_provider_context(UUID, TEXT)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.link_billing_provider_identity(UUID, TEXT, TEXT, TEXT)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.billing_profile_for_provider_customer(TEXT, TEXT)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.billing_profile_for_provider_subscription(TEXT, TEXT)
    TO service_role;
