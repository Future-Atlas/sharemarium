-- Follow-up hardening for retained favorites.
--
-- Keep the historical insert policy name so the existing policy contract test
-- remains meaningful, but restrict that policy to INSERT. DELETE stays a
-- separate explicit owner-only policy and hidden rows remain protected by the
-- SELECT policy introduced in the previous migration.
DROP POLICY IF EXISTS "Users can insert their own favorites"
    ON public.favorites;
DROP POLICY IF EXISTS "Allow authenticated users to insert/delete favorites"
    ON public.favorites;
CREATE POLICY "Allow authenticated users to insert/delete favorites"
    ON public.favorites
    FOR INSERT TO authenticated
    WITH CHECK (
        auth.uid() = profile_id
        AND public.is_profile_active(auth.uid())
    );

-- When replacing a visible favorite, hide the released slot first while the
-- retained row count is still above the cap. This prevents an older hidden row
-- from being automatically exposed during the short interval between DELETE
-- and INSERT inside the same transaction.
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

    -- Release the visible slot without reducing total retained rows yet.
    UPDATE public.favorites
       SET is_visible = FALSE
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

    -- Preserve the established replacement behavior for the explicitly
    -- replaced row. Other hidden retained favorites are untouched.
    DELETE FROM public.favorites
     WHERE profile_id = current_profile_id
       AND book_id = p_remove_book_id;

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

-- Temporary compatibility RPC for the Flutter client path that historically
-- pre-checked favorites as if every paid account had a finite limit. The RPC
-- is strictly Premium-only and still relies on the database trigger and the
-- completed-post invariant. It can be removed once all clients use plan-aware
-- favorite mutations directly.
CREATE OR REPLACE FUNCTION public.add_current_user_premium_favorite(
    p_book_id TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    current_profile_id UUID := auth.uid();
BEGIN
    IF current_profile_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
    END IF;

    IF p_book_id IS NULL OR btrim(p_book_id) = '' THEN
        RAISE EXCEPTION 'Book ID is required' USING ERRCODE = '22023';
    END IF;

    IF NOT public.is_profile_active(current_profile_id) THEN
        RAISE EXCEPTION 'Account is unavailable' USING ERRCODE = '42501';
    END IF;

    IF private.profile_effective_subscription_plan(current_profile_id) <> 'premium' THEN
        RAISE EXCEPTION 'premium_subscription_required' USING ERRCODE = '42501';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(current_profile_id::text)::bigint);

    IF NOT EXISTS (
        SELECT 1
        FROM public.posts
        WHERE profile_id = current_profile_id
          AND book_id = p_book_id
    ) THEN
        RAISE EXCEPTION 'favorite_requires_post' USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.favorites
        WHERE profile_id = current_profile_id
          AND book_id = p_book_id
    ) THEN
        UPDATE public.favorites
           SET is_visible = TRUE
         WHERE profile_id = current_profile_id
           AND book_id = p_book_id;
        RETURN 'already_favorited';
    END IF;

    INSERT INTO public.favorites (profile_id, book_id, is_visible)
    VALUES (current_profile_id, p_book_id, TRUE);

    RETURN 'added';
END;
$$;

REVOKE ALL ON FUNCTION public.replace_current_user_favorite(TEXT, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_current_user_favorite(TEXT, TEXT)
    TO authenticated;

REVOKE ALL ON FUNCTION public.add_current_user_premium_favorite(TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_current_user_premium_favorite(TEXT)
    TO authenticated;

COMMENT ON FUNCTION public.add_current_user_premium_favorite(TEXT) IS
    'Premium-only favorite insert path used by clients while legacy finite-limit prechecks are phased out.';
