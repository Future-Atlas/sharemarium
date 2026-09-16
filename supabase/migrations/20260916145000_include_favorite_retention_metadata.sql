-- Avoid one external book API request per retained favorite when a downgraded
-- user opens the selection dialog. Favorites can only be created for books the
-- user has posted about, so reuse the latest stored post metadata in the
-- owner-only management RPC.
DROP FUNCTION IF EXISTS public.current_user_favorite_retention_candidates();

CREATE FUNCTION public.current_user_favorite_retention_candidates()
RETURNS TABLE (
    book_id TEXT,
    created_at TIMESTAMP WITH TIME ZONE,
    is_selected BOOLEAN,
    book_title TEXT,
    book_author TEXT,
    book_cover_url TEXT
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
        ) AS is_selected,
        coalesce(latest_post.book_title, favorite.book_id) AS book_title,
        coalesce(latest_post.book_author, '') AS book_author,
        coalesce(latest_post.book_cover_url, '') AS book_cover_url
    FROM public.favorites AS favorite
    LEFT JOIN LATERAL (
        SELECT
            post.book_title,
            post.book_author,
            post.book_cover_url
        FROM public.posts AS post
        WHERE post.profile_id = favorite.profile_id
          AND post.book_id = favorite.book_id
        ORDER BY post.created_at DESC, post.id DESC
        LIMIT 1
    ) AS latest_post ON TRUE
    WHERE auth.uid() IS NOT NULL
      AND favorite.profile_id = auth.uid()
    ORDER BY favorite.created_at DESC, favorite.book_id ASC;
$$;

REVOKE ALL ON FUNCTION public.current_user_favorite_retention_candidates()
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_favorite_retention_candidates()
    TO authenticated;

COMMENT ON FUNCTION public.current_user_favorite_retention_candidates() IS
    'Returns every retained favorite for auth.uid(), including hidden rows and local post metadata, for the downgrade selection flow.';
