-- Model Sharemarium Free / Plus / Premium independently from the future
-- payment provider. Existing boolean subscription entitlements are migrated to
-- Premium so currently entitled accounts do not lose access.

ALTER TABLE private.subscription_entitlements
    ADD COLUMN IF NOT EXISTS plan TEXT NOT NULL DEFAULT 'free',
    ADD COLUMN IF NOT EXISTS scheduled_plan TEXT,
    ADD COLUMN IF NOT EXISTS scheduled_plan_effective_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS current_period_end TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS payment_grace_until TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS trial_used BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS billing_status TEXT NOT NULL DEFAULT 'manual',
    ADD COLUMN IF NOT EXISTS billing_provider TEXT,
    ADD COLUMN IF NOT EXISTS provider_customer_id TEXT;

ALTER TABLE private.subscription_entitlements
    DROP CONSTRAINT IF EXISTS subscription_entitlements_plan_check;
ALTER TABLE private.subscription_entitlements
    ADD CONSTRAINT subscription_entitlements_plan_check
    CHECK (plan IN ('free', 'plus', 'premium'));

ALTER TABLE private.subscription_entitlements
    DROP CONSTRAINT IF EXISTS subscription_entitlements_scheduled_plan_check;
ALTER TABLE private.subscription_entitlements
    ADD CONSTRAINT subscription_entitlements_scheduled_plan_check
    CHECK (
        scheduled_plan IS NULL
        OR scheduled_plan IN ('free', 'plus', 'premium')
    );

ALTER TABLE private.subscription_entitlements
    DROP CONSTRAINT IF EXISTS subscription_entitlements_billing_status_check;
ALTER TABLE private.subscription_entitlements
    ADD CONSTRAINT subscription_entitlements_billing_status_check
    CHECK (billing_status IN ('manual', 'trialing', 'active', 'past_due', 'canceled'));

CREATE UNIQUE INDEX IF NOT EXISTS subscription_entitlements_provider_customer_uidx
    ON private.subscription_entitlements (billing_provider, provider_customer_id)
    WHERE billing_provider IS NOT NULL AND provider_customer_id IS NOT NULL;

-- The old schema had only is_active. Treat every still-active legacy grant as
-- Premium because it previously unlocked replies, want-to-read, and the full
-- page-color palette. This also preserves administrator/test grants.
UPDATE private.subscription_entitlements
SET plan = CASE WHEN is_active THEN 'premium' ELSE 'free' END,
    current_period_end = COALESCE(current_period_end, expires_at),
    billing_status = CASE
        WHEN billing_status = 'manual' THEN 'manual'
        ELSE billing_status
    END,
    updated_at = timezone('utc'::text, now());

COMMENT ON TABLE private.subscription_entitlements IS
    'Private subscription lifecycle state. Billing provider webhooks may update it later; Free/Plus/Premium feature checks are provider-independent.';
COMMENT ON COLUMN private.subscription_entitlements.plan IS
    'Current configured plan: free, plus, or premium.';
COMMENT ON COLUMN private.subscription_entitlements.scheduled_plan IS
    'Plan to apply on scheduled_plan_effective_at, normally the next renewal date.';
COMMENT ON COLUMN private.subscription_entitlements.payment_grace_until IS
    'Past-due accounts keep their current paid plan until this timestamp.';
COMMENT ON COLUMN private.subscription_entitlements.trial_used IS
    'True after the account has consumed its one Sharemarium paid-plan trial.';

CREATE OR REPLACE FUNCTION private.profile_effective_subscription_plan(
    target_profile_id UUID
)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT COALESCE(
        (
            SELECT CASE
                WHEN entitlement.is_active IS NOT TRUE THEN 'free'
                WHEN entitlement.billing_status = 'past_due'
                     AND (
                        entitlement.payment_grace_until IS NULL
                        OR entitlement.payment_grace_until <= timezone('utc'::text, now())
                     ) THEN 'free'
                WHEN entitlement.billing_status = 'trialing'
                     AND entitlement.trial_ends_at IS NOT NULL
                     AND entitlement.trial_ends_at <= timezone('utc'::text, now())
                     THEN 'free'
                WHEN entitlement.expires_at IS NOT NULL
                     AND entitlement.expires_at <= timezone('utc'::text, now())
                     AND (
                        entitlement.payment_grace_until IS NULL
                        OR entitlement.payment_grace_until <= timezone('utc'::text, now())
                     ) THEN 'free'
                WHEN entitlement.scheduled_plan IS NOT NULL
                     AND entitlement.scheduled_plan_effective_at IS NOT NULL
                     AND entitlement.scheduled_plan_effective_at <= timezone('utc'::text, now())
                     THEN entitlement.scheduled_plan
                WHEN entitlement.cancel_at_period_end
                     AND entitlement.current_period_end IS NOT NULL
                     AND entitlement.current_period_end <= timezone('utc'::text, now())
                     THEN 'free'
                ELSE entitlement.plan
            END
            FROM private.subscription_entitlements AS entitlement
            WHERE entitlement.profile_id = target_profile_id
        ),
        'free'
    );
$$;

REVOKE ALL ON FUNCTION private.profile_effective_subscription_plan(UUID)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.profile_effective_subscription_plan(UUID)
    TO service_role;

CREATE OR REPLACE FUNCTION private.profile_has_active_subscription(
    target_profile_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT private.profile_effective_subscription_plan(target_profile_id)
        IN ('plus', 'premium');
$$;

REVOKE ALL ON FUNCTION private.profile_has_active_subscription(UUID)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.profile_has_active_subscription(UUID)
    TO service_role;

CREATE OR REPLACE FUNCTION public.current_user_subscription_plan()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT CASE
        WHEN auth.uid() IS NULL THEN 'free'
        ELSE private.profile_effective_subscription_plan(auth.uid())
    END;
$$;

REVOKE ALL ON FUNCTION public.current_user_subscription_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_subscription_plan()
    TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.current_user_subscription_state()
RETURNS TABLE (
    effective_plan TEXT,
    scheduled_plan TEXT,
    scheduled_plan_effective_at TIMESTAMP WITH TIME ZONE,
    current_period_end TIMESTAMP WITH TIME ZONE,
    payment_grace_until TIMESTAMP WITH TIME ZONE,
    trial_ends_at TIMESTAMP WITH TIME ZONE,
    trial_used BOOLEAN,
    cancel_at_period_end BOOLEAN,
    billing_status TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        CASE
            WHEN auth.uid() IS NULL THEN 'free'
            ELSE private.profile_effective_subscription_plan(auth.uid())
        END,
        entitlement.scheduled_plan,
        entitlement.scheduled_plan_effective_at,
        entitlement.current_period_end,
        entitlement.payment_grace_until,
        entitlement.trial_ends_at,
        COALESCE(entitlement.trial_used, false),
        COALESCE(entitlement.cancel_at_period_end, false),
        COALESCE(entitlement.billing_status, 'manual')
    FROM (SELECT 1) AS singleton
    LEFT JOIN private.subscription_entitlements AS entitlement
      ON entitlement.profile_id = auth.uid();
$$;

REVOKE ALL ON FUNCTION public.current_user_subscription_state() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_subscription_state()
    TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.current_user_has_ad_free_access()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT public.current_user_subscription_plan() IN ('plus', 'premium');
$$;

REVOKE ALL ON FUNCTION public.current_user_has_ad_free_access() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_has_ad_free_access()
    TO anon, authenticated;

-- Free: 3, Plus: 12, Premium: effectively unlimited. INTEGER max preserves
-- the existing integer RPC contract while the trigger below skips the count
-- check entirely for Premium.
CREATE OR REPLACE FUNCTION public.current_user_favorite_limit()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT CASE public.current_user_subscription_plan()
        WHEN 'premium' THEN 2147483647
        WHEN 'plus' THEN 12
        ELSE 3
    END;
$$;

REVOKE ALL ON FUNCTION public.current_user_favorite_limit() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_favorite_limit()
    TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_favorites_limit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    effective_plan TEXT;
    favorite_limit INTEGER;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext(NEW.profile_id::text)::bigint);

    IF NOT EXISTS (
        SELECT 1
        FROM public.posts
        WHERE profile_id = NEW.profile_id
          AND book_id = NEW.book_id
    ) THEN
        RAISE EXCEPTION 'favorite_requires_post'
            USING ERRCODE = 'P0001';
    END IF;

    effective_plan := private.profile_effective_subscription_plan(NEW.profile_id);
    IF effective_plan = 'premium' THEN
        RETURN NEW;
    END IF;

    favorite_limit := CASE WHEN effective_plan = 'plus' THEN 12 ELSE 3 END;

    IF (
        SELECT count(*)
        FROM public.favorites
        WHERE profile_id = NEW.profile_id
    ) >= favorite_limit THEN
        RAISE EXCEPTION 'favorite_limit_reached'
            USING ERRCODE = 'P0001',
                  DETAIL = format('favorite_limit=%s', favorite_limit);
    END IF;

    RETURN NEW;
END;
$$;

-- Only Premium unlocks the complete color palette. Preserve the explicit
-- pre-lock legacy color entitlement for backwards compatibility.
CREATE OR REPLACE FUNCTION public.current_user_can_use_all_page_colors()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL
       AND (
            private.profile_effective_subscription_plan(auth.uid()) = 'premium'
            OR EXISTS (
                SELECT 1
                FROM private.page_color_legacy_entitlements AS entitlement
                WHERE entitlement.profile_id = auth.uid()
            )
       );
$$;

REVOKE ALL ON FUNCTION public.current_user_can_use_all_page_colors()
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_can_use_all_page_colors()
    TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_profile_page_color_entitlement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NEW.page_color NOT IN ('blue', 'yellow', 'green')
       AND NOT (
            private.profile_effective_subscription_plan(NEW.id) = 'premium'
            OR EXISTS (
                SELECT 1
                FROM private.page_color_legacy_entitlements AS entitlement
                WHERE entitlement.profile_id = NEW.id
            )
       ) THEN
        RAISE EXCEPTION 'page_color_subscription_required'
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_profile_page_color_entitlement()
    FROM PUBLIC, anon, authenticated;

-- Want-to-read is Premium-only. Existing rows remain stored so a future
-- Premium reactivation can reveal them again.
CREATE OR REPLACE FUNCTION public.current_user_can_use_want_to_read()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL
       AND private.profile_effective_subscription_plan(auth.uid()) = 'premium';
$$;

REVOKE ALL ON FUNCTION public.current_user_can_use_want_to_read() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_can_use_want_to_read()
    TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.profile_can_expose_want_to_read(
    target_profile_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT private.profile_effective_subscription_plan(target_profile_id) = 'premium'
       AND public.can_view_profile_content(target_profile_id);
$$;

REVOKE ALL ON FUNCTION public.profile_can_expose_want_to_read(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.profile_can_expose_want_to_read(UUID)
    TO anon, authenticated;

-- Legacy individual reply grants remain a full-access administrator override.
CREATE OR REPLACE FUNCTION public.current_user_reply_tier()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT CASE
        WHEN auth.uid() IS NULL THEN 'free'
        WHEN EXISTS (
            SELECT 1
            FROM private.reply_entitlements AS entitlement
            WHERE entitlement.profile_id = auth.uid()
              AND entitlement.can_reply = true
        ) THEN 'premium'
        ELSE private.profile_effective_subscription_plan(auth.uid())
    END;
$$;

REVOKE ALL ON FUNCTION public.current_user_reply_tier() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_reply_tier()
    TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.current_user_can_reply()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT public.current_user_reply_tier() IN ('plus', 'premium');
$$;

REVOKE ALL ON FUNCTION public.current_user_can_reply() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_can_reply()
    TO anon, authenticated;

-- Plus: one top-level reply per other user's post.
-- Premium / legacy administrator override: multiple replies and reply threads.
CREATE OR REPLACE FUNCTION public.create_post_reply(
    target_post UUID,
    reply_message TEXT,
    target_reply BIGINT DEFAULT NULL,
    reply_has_spoiler BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    actor UUID := auth.uid();
    created_reply_id BIGINT;
    reply_tier TEXT;
    target_post_owner UUID;
BEGIN
    IF actor IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Authentication is required';
    END IF;

    IF NOT public.is_profile_active(actor) THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Account is not active';
    END IF;

    reply_tier := public.current_user_reply_tier();
    IF reply_tier = 'free' THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Reply entitlement is required';
    END IF;

    SELECT post.profile_id
      INTO target_post_owner
      FROM public.posts AS post
     WHERE post.id = target_post
       AND public.can_view_profile_content(post.profile_id);

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P0002',
            MESSAGE = 'Target post is not available';
    END IF;

    IF target_reply IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM public.post_replies AS parent
        WHERE parent.id = target_reply
          AND parent.post_id = target_post
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23503',
            MESSAGE = 'Parent reply is not available';
    END IF;

    IF reply_tier = 'plus' THEN
        IF target_post_owner = actor THEN
            RAISE EXCEPTION USING
                ERRCODE = '42501',
                MESSAGE = 'Plus replies are limited to other users posts';
        END IF;
        IF target_reply IS NOT NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '42501',
                MESSAGE = 'Plus does not allow replies to replies';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM public.post_replies AS existing
            WHERE existing.post_id = target_post
              AND existing.profile_id = actor
              AND existing.parent_reply_id IS NULL
        ) THEN
            RAISE EXCEPTION USING
                ERRCODE = '42501',
                MESSAGE = 'Plus allows one top-level reply per post';
        END IF;
    END IF;

    INSERT INTO public.post_replies (
        post_id,
        profile_id,
        parent_reply_id,
        message,
        has_spoiler
    )
    VALUES (
        target_post,
        actor,
        target_reply,
        reply_message,
        COALESCE(reply_has_spoiler, FALSE)
    )
    RETURNING id INTO created_reply_id;

    RETURN created_reply_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_post_reply(UUID, TEXT, BIGINT, BOOLEAN)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_post_reply(UUID, TEXT, BIGINT, BOOLEAN)
    TO authenticated;

-- Only active Premium shelves contribute to the current want-to-read total.
CREATE OR REPLACE FUNCTION public.get_book_engagement_counts(target_book_id TEXT)
RETURNS TABLE(read_count BIGINT, want_to_read_count BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        (SELECT count(*) FROM public.posts WHERE book_id = target_book_id),
        (
            SELECT count(*)
            FROM public.want_to_read_books AS wanted
            WHERE wanted.book_id = target_book_id
              AND private.profile_effective_subscription_plan(wanted.profile_id) = 'premium'
        );
$$;

REVOKE ALL ON FUNCTION public.get_book_engagement_counts(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_book_engagement_counts(TEXT)
    TO anon, authenticated;
