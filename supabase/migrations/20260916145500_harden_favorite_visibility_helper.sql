-- Do not expose the internal retained-row visibility helper directly to
-- application roles. It intentionally knows whether a retained favorite row
-- exists, so callers should only reach it through a wrapper that also enforces
-- the profile visibility rule.
CREATE OR REPLACE FUNCTION public.can_view_favorite(
    target_profile_id UUID,
    target_book_id TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT public.can_view_profile_content(target_profile_id)
       AND private.favorite_is_effectively_visible(
            target_profile_id,
            target_book_id
       );
$$;

REVOKE ALL ON FUNCTION private.favorite_is_effectively_visible(UUID, TEXT)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.favorite_is_effectively_visible(UUID, TEXT)
    TO service_role;

REVOKE ALL ON FUNCTION public.can_view_favorite(UUID, TEXT)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_view_favorite(UUID, TEXT)
    TO anon, authenticated;

DROP POLICY IF EXISTS "Allow visible profile favorites to be read"
    ON public.favorites;
CREATE POLICY "Allow visible profile favorites to be read"
    ON public.favorites
    FOR SELECT
    USING (public.can_view_favorite(profile_id, book_id));

COMMENT ON FUNCTION public.can_view_favorite(UUID, TEXT) IS
    'Safe RLS visibility predicate: profile visibility and retained favorite visibility must both allow the row.';
