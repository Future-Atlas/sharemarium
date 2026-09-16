-- Remember that a user completed the downgrade selection for a specific cap.
-- Without this marker, intentionally removing one visible favorite later would
-- look identical to an unfinished downgrade selection and could force the user
-- to fill every available slot again. Favorite limits are maxima, not minima.
CREATE TABLE IF NOT EXISTS private.favorite_retention_preferences (
    profile_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    selected_limit INTEGER NOT NULL CHECK (selected_limit > 0),
    confirmed_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now())
);

REVOKE ALL ON TABLE private.favorite_retention_preferences
    FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.favorite_retention_preferences
    TO service_role;

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
            WHEN preference.selected_limit IS DISTINCT FROM plan_state.favorite_limit THEN TRUE
            WHEN counts.selected_count > plan_state.favorite_limit THEN TRUE
            ELSE FALSE
        END AS selection_required
    FROM plan_state
    JOIN counts USING (profile_id)
    LEFT JOIN private.favorite_retention_preferences AS preference
      ON preference.profile_id = plan_state.profile_id;
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

    INSERT INTO private.favorite_retention_preferences (
        profile_id,
        selected_limit,
        confirmed_at,
        updated_at
    ) VALUES (
        current_profile_id,
        favorite_limit,
        timezone('utc'::text, now()),
        timezone('utc'::text, now())
    )
    ON CONFLICT (profile_id) DO UPDATE
      SET selected_limit = EXCLUDED.selected_limit,
          confirmed_at = EXCLUDED.confirmed_at,
          updated_at = EXCLUDED.updated_at;

    RETURN 'updated';
END;
$$;

REVOKE ALL ON FUNCTION public.current_user_favorite_retention_state()
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_favorite_retention_state()
    TO authenticated;

REVOKE ALL ON FUNCTION public.set_current_user_visible_favorites(TEXT[])
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_current_user_visible_favorites(TEXT[])
    TO authenticated;

COMMENT ON TABLE private.favorite_retention_preferences IS
    'Tracks the capped plan limit for which the user last completed favorite retention selection; allows them to later keep fewer than the maximum without being re-prompted.';
