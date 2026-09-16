-- Replace a favorite in one transaction so standard-plan users can swap one
-- of their three saved books without a temporary limit error.
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
    ) THEN
        RAISE EXCEPTION 'Favorite not found' USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.favorites
        WHERE profile_id = current_profile_id
          AND book_id = p_add_book_id
    ) THEN
        RETURN 'already_favorited';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.posts
        WHERE profile_id = current_profile_id
          AND book_id = p_add_book_id
    ) THEN
        RAISE EXCEPTION 'favorite_requires_post' USING ERRCODE = 'P0001';
    END IF;

    DELETE FROM public.favorites
    WHERE profile_id = current_profile_id
      AND book_id = p_remove_book_id;

    INSERT INTO public.favorites (profile_id, book_id)
    VALUES (current_profile_id, p_add_book_id);

    RETURN 'replaced';
END;
$$;

REVOKE ALL ON FUNCTION public.replace_current_user_favorite(TEXT, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_current_user_favorite(TEXT, TEXT)
    TO authenticated;

COMMENT ON FUNCTION public.replace_current_user_favorite(TEXT, TEXT) IS
    'Atomically replaces one of the authenticated user''s favorites.';
