-- Preserve favorite rows across subscription downgrades while exposing only
-- the number allowed by the current effective plan.
--
-- Premium always exposes every retained favorite. Free/Plus expose a user-
-- selected subset (3/12). If a downgrade has just taken effect and the user
-- has not chosen a subset yet, the newest allowed favorites are exposed as a
-- deterministic temporary default and the retention state reports that a
-- selection is required.

ALTER TABLE public.favorites
    ADD COLUMN IF NOT EXISTS is_visible BOOLEAN NOT NULL DEFAULT TRUE;

CREATE INDEX IF NOT EXISTS favorites_profile_visibility_created_idx
    ON public.favorites (profile_id, is_visible, created_at DESC, book_id);

CREATE OR REPLACE FUNCTION private.profile_favorite_limit(
    target_profile_id UUID
)
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT CASE private.profile_effective_subscription_plan(target_profile_id)
        WHEN 'premium' THEN 2147483647
        WHEN 'plus' THEN 12
        ELSE 3
    END;
$$;

CREATE OR REPLACE FUNCTION private.favorite_is_effectively_visible(
    target_profile_id UUID,
    target_book_id TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    WITH plan_state AS (
        SELECT
            private.profile_effective_subscription_plan(target_profile_id) AS effective_plan,
            private.profile_favorite_limit(target_profile_id) AS favorite_limit
    ),
    totals AS (
        SELECT count(*)::INTEGER AS total_count
        FROM public.favorites
        WHERE profile_id = target_profile_id
    ),
    ranked_visible AS (
        SELECT
            favorite.book_id,
            row_number() OVER (
                ORDER BY favorite.created_at DESC, favorite.book_id ASC
            ) AS visible_rank
        FROM public.favorites AS favorite
        WHERE favorite.profile_id = target_profile_id
          AND favorite.is_visible = TRUE
    )
    SELECT CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM public.favorites AS favorite
            WHERE favorite.profile_id = target_profile_id
              AND favorite.book_id = target_book_id
        ) THEN FALSE
        WHEN (SELECT effective_plan FROM plan_state) = 'premium' THEN TRUE
        WHEN (SELECT total_count FROM totals) <= (SELECT favorite_limit FROM plan_state)
            THEN TRUE
        ELSE EXISTS (
            SELECT 1
            FROM ranked_visible
            WHERE ranked_visible.book_id = target_book_id
              AND ranked_visible.visible_rank <= (SELECT favorite_limit FROM plan_state)
        )
    END;
$$;

-- The previous FOR ALL policy also granted owners SELECT access to every row,
-- which would make hidden retained favorites visible to the existing Flutter
-- query. Replace it with explicit write policies and make SELECT honor the
-- effective favorite visibility rule for owners and visitors alike.
DROP POLICY IF EXISTS "Allow authenticated users to insert/delete favorites"
    ON public.favorites;
DROP POLICY IF EXISTS "Allow visible profile favorites to be read"
    ON public.favorites;
DROP POLICY IF EXISTS "Users can insert their own favorites"
    ON public.favorites;
DROP POLICY IF EXISTS "Users can delete their own favorites"
    ON public.favorites;

CREATE POLICY "Allow visible profile favorites to be read"
    ON public.favorites
    FOR SELECT
    USING (
        public.can_view_profile_content(profile_id)
        AND private.favorite_is_effectively_visible(profile_id, book_id)
    );

CREATE POLICY "Users can insert their own favorites"
    ON public.favorites
    FOR INSERT TO authenticated
    WITH CHECK (
        auth.uid() = profile_id
        AND public.is_profile_active(auth.uid())
    );

CREATE POLICY "Users can delete their own favorites"
    ON public.favorites
    FOR DELETE TO authenticated
    USING (
        auth.uid() = profile_id
        AND public.is_profile_active(auth.uid())
    );

-- Return whether the current account has retained favorites that exceed its
-- effective plan and still needs to choose the subset that remains visible.
CREATE OR REPLACE FUNCTION public.current_user_favorite_retention_state()
RETURNS TABLE (
    effective_plan TEXT,
    favorite_limit INTEGER,
    total_count INTEGER,
    effective_visible_count INTEGER,
    selection_required BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    WITH current_profile AS (
        SELECT auth.uid() AS profile_id
    ),
    plan_state AS (
        SELECT
            current_profile.profile_id,
            private.profile_effective_subscription_plan(current_profile.profile_id) AS effective_plan,
            private.profile_favorite_limit(current_profile.profile_id) AS favorite_limit
        FROM current_profile
        WHERE current_profile.profile_id IS NOT NULL
    ),
    counts AS (
        SELECT
            plan_state.profile_id,
            count(favorite.book_id)::INTEGER AS total_count,
            count(favorite.book_id) FILTER (WHERE favorite.is_visible)::INTEGER AS selected_count,
            count(favorite.book_id) FILTER (
                WHERE private.favorite_is_effectively_visible(
                    favorite.profile_id,
                    favorite.book_id
                )
            )::INTEGER AS effective_visible_count
        FROM plan_state
        LEFT JOIN public.favorites AS favorite
          ON favorite.profile_id = plan_state.profile_id
        GROUP BY plan_state.profile_id
    )
    SELECT
        plan_state.effective_plan,
        plan_state.favorite_limit,
        counts.total_count,
        counts.effective_visible_count,
        CASE
            WHEN plan_state.effective_plan = 'premium' THEN FALSE
            WHEN counts.total_count <= plan_state.favorite_limit THEN FALSE
            ELSE counts.selected_count <> plan_state.favorite_limit
        END AS selection_required
    FROM plan_state
    JOIN counts USING (profile_id);
$$;

-- Management candidates intentionally bypass the normal favorites SELECT RLS,
-- but only for auth.uid(), so hidden retained rows never leak to another user.
CREATE OR REPLACE FUNCTION public.current_user_favorite_retention_candidates()
RETURNS TABLE (
    book_id TEXT,
    created_at TIMESTAMP WITH TIME ZONE,
    is_selected BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        favorite.book_id,
        favorite.created_at,
        private.favorite_is_effectively_visible(
            favorite.profile_id,
            favorite.book_id
        ) AS is_selected
    FROM public.favorites AS favorite
    WHERE auth.uid() IS NOT NULL
      AND favorite.profile_id = auth.uid()
    ORDER BY favorite.created_at DESC, favorite.book_id ASC;
$$;

CREATE OR REPLACE FUNCTION public.set_current_user_visible_favorites(
    p_book_ids TEXT[]
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    current_profile_id UUID := auth.uid();
    effective_plan TEXT;
    favorite_limit INTEGER;
    total_count INTEGER;
    selected_ids TEXT[];
    selected_count INTEGER;
    owned_selected_count INTEGER;
BEGIN
    IF current_profile_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public.is_profile_active(current_profile_id) THEN
        RAISE EXCEPTION 'Account is unavailable'
            USING ERRCODE = '42501';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(current_profile_id::text)::bigint);

    effective_plan := private.profile_effective_subscription_plan(current_profile_id);
    favorite_limit := private.profile_favorite_limit(current_profile_id);

    SELECT count(*)::INTEGER
      INTO total_count
      FROM public.favorites
     WHERE profile_id = current_profile_id;

    IF effective_plan = 'premium' OR total_count <= favorite_limit THEN
        UPDATE public.favorites
           SET is_visible = TRUE
         WHERE profile_id = current_profile_id
           AND is_visible = FALSE;
        RETURN 'not_required';
    END IF;

    SELECT
        coalesce(array_agg(book_id ORDER BY book_id), ARRAY[]::TEXT[]),
        count(*)::INTEGER
      INTO selected_ids, selected_count
      FROM (
          SELECT DISTINCT btrim(candidate) AS book_id
          FROM unnest(coalesce(p_book_ids, ARRAY[]::TEXT[])) AS candidate
          WHERE btrim(candidate) <> ''
      ) AS normalized;

    IF selected_count <> favorite_limit THEN
        RAISE EXCEPTION 'favorite_selection_count_mismatch'
            USING ERRCODE = '22023',
                  DETAIL = format(
                      'required=%s selected=%s',
                      favorite_limit,
                      selected_count
                  );
    END IF;

    SELECT count(*)::INTEGER
      INTO owned_selected_count
      FROM public.favorites
     WHERE profile_id = current_profile_id
       AND book_id = ANY(selected_ids);

    IF owned_selected_count <> selected_count THEN
        RAISE EXCEPTION 'favorite_selection_contains_unknown_book'
            USING ERRCODE = '22023';
    END IF;

    UPDATE public.favorites
       SET is_visible = (book_id = ANY(selected_ids))
     WHERE profile_id = current_profile_id;

    RETURN 'updated';
END;
$$;

-- Count only the effective visible shelf when enforcing additions. Retained
-- hidden favorites must not block a user from replacing one of the currently
-- visible slots after a downgrade.
CREATE OR REPLACE FUNCTION public.enforce_favorites_limit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    effective_plan TEXT;
    favorite_limit INTEGER;
    effective_visible_count INTEGER;
    existing_row_exists BOOLEAN;
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
        NEW.is_visible := TRUE;
        RETURN NEW;
    END IF;

    favorite_limit := private.profile_favorite_limit(NEW.profile_id);

    SELECT EXISTS (
        SELECT 1
        FROM public.favorites AS favorite
        WHERE favorite.profile_id = NEW.profile_id
          AND favorite.book_id = NEW.book_id
    ) INTO existing_row_exists;

    SELECT count(*)::INTEGER
      INTO effective_visible_count
      FROM public.favorites AS favorite
     WHERE favorite.profile_id = NEW.profile_id
       AND private.favorite_is_effectively_visible(
            favorite.profile_id,
            favorite.book_id
       );

    IF effective_visible_count >= favorite_limit THEN
        RAISE EXCEPTION 'favorite_limit_reached'
            USING ERRCODE = 'P0001',
                  DETAIL = format('favorite_limit=%s', favorite_limit);
    END IF;

    -- Re-favoriting a retained hidden book restores that row instead of
    -- violating the (profile_id, book_id) primary key.
    IF existing_row_exists THEN
        UPDATE public.favorites
           SET is_visible = TRUE
         WHERE profile_id = NEW.profile_id
           AND book_id = NEW.book_id;
        RETURN NULL;
    END IF;

    NEW.is_visible := TRUE;
    RETURN NEW;
END;
$$;

-- Keep the existing replacement UX, but make it compatible with retained
-- hidden rows. The removed visible favorite is still deleted (the historical
-- behavior), while a target that already exists hidden is restored atomically.
CREATE OR REPLACE FUNCTION public.replace_current_user_favorite(
    p_remove_book_id TEXT,
    p_add_book_id TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    current_profile_id UUID := auth.uid();
    favorite_limit INTEGER;
    visible_count INTEGER;
    target_exists BOOLEAN;
BEGIN
    IF current_profile_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
    END IF;

    IF p_remove_book_id IS NULL OR btrim(p_remove_book_id) = ''
       OR p_add_book_id IS NULL OR btrim(p_add_book_id) = '' THEN
        RAISE EXCEPTION 'Book ID is required' USING ERRCODE = '22023';
    END IF;

    IF p_remove_book_id = p_add_book_id THEN
        RETURN 'already_favorited';
    END IF;

    IF NOT public.is_profile_active(current_profile_id) THEN
        RAISE EXCEPTION 'Account is unavailable' USING ERRCODE = '42501';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(current_profile_id::text)::bigint);

    IF NOT EXISTS (
        SELECT 1
        FROM public.favorites
        WHERE profile_id = current_profile_id
          AND book_id = p_remove_book_id
          AND private.favorite_is_effectively_visible(profile_id, book_id)
    ) THEN
        RAISE EXCEPTION 'Favorite not found' USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.posts
        WHERE profile_id = current_profile_id
          AND book_id = p_add_book_id
    ) THEN
        RAISE EXCEPTION 'favorite_requires_post' USING ERRCODE = 'P0001';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.favorites
        WHERE profile_id = current_profile_id
          AND book_id = p_add_book_id
    ) INTO target_exists;

    DELETE FROM public.favorites
     WHERE profile_id = current_profile_id
       AND book_id = p_remove_book_id;

    IF target_exists THEN
        UPDATE public.favorites
           SET is_visible = TRUE
         WHERE profile_id = current_profile_id
           AND book_id = p_add_book_id;
    ELSE
        INSERT INTO public.favorites (profile_id, book_id, is_visible)
        VALUES (current_profile_id, p_add_book_id, TRUE);
    END IF;

    favorite_limit := private.profile_favorite_limit(current_profile_id);
    IF favorite_limit < 2147483647 THEN
        SELECT count(*)::INTEGER
          INTO visible_count
          FROM public.favorites AS favorite
         WHERE favorite.profile_id = current_profile_id
           AND private.favorite_is_effectively_visible(
                favorite.profile_id,
                favorite.book_id
           );
        IF visible_count > favorite_limit THEN
            RAISE EXCEPTION 'favorite_limit_reached'
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    RETURN 'replaced';
END;
$$;

REVOKE ALL ON FUNCTION private.profile_favorite_limit(UUID)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.favorite_is_effectively_visible(UUID, TEXT)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.favorite_is_effectively_visible(UUID, TEXT)
    TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.profile_favorite_limit(UUID)
    TO service_role;

REVOKE ALL ON FUNCTION public.current_user_favorite_retention_state()
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_favorite_retention_state()
    TO authenticated;

REVOKE ALL ON FUNCTION public.current_user_favorite_retention_candidates()
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_favorite_retention_candidates()
    TO authenticated;

REVOKE ALL ON FUNCTION public.set_current_user_visible_favorites(TEXT[])
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_current_user_visible_favorites(TEXT[])
    TO authenticated;

REVOKE ALL ON FUNCTION public.replace_current_user_favorite(TEXT, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_current_user_favorite(TEXT, TEXT)
    TO authenticated;

COMMENT ON COLUMN public.favorites.is_visible IS
    'User-selected visibility for capped plans. Premium ignores this flag and restores every retained favorite.';
COMMENT ON FUNCTION public.current_user_favorite_retention_state() IS
    'Reports whether a downgraded account must choose which retained favorites stay visible.';
COMMENT ON FUNCTION public.current_user_favorite_retention_candidates() IS
    'Returns every retained favorite for auth.uid(), including hidden rows, for the downgrade selection flow.';
COMMENT ON FUNCTION public.set_current_user_visible_favorites(TEXT[]) IS
    'Stores the exact visible favorite subset required by the current Free/Plus limit without deleting hidden retained rows.';
