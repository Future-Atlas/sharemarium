-- Public browsing is intentionally available without authentication.
-- Reply entitlement only controls reply creation; it must never gate reading
-- public posts/replies or creating ordinary review posts.
--
-- Preserve the existing privacy, suspension, block, and age-restriction rules.

GRANT SELECT ON public.profiles TO anon, authenticated;
GRANT SELECT ON public.posts TO anon, authenticated;
GRANT SELECT ON public.post_replies TO anon, authenticated;

DROP POLICY IF EXISTS "Allow visible profile posts to be read" ON public.posts;
CREATE POLICY "Allow visible profile posts to be read"
    ON public.posts FOR SELECT TO anon, authenticated
    USING (
        public.can_view_profile_content(profile_id)
        AND (
            is_age_restricted = false
            OR public.current_user_can_view_age_restricted()
        )
    );

DROP POLICY IF EXISTS "Public can read post replies" ON public.post_replies;
DROP POLICY IF EXISTS "Visible post replies can be read" ON public.post_replies;
CREATE POLICY "Visible post replies can be read"
    ON public.post_replies FOR SELECT TO anon, authenticated
    USING (
        public.can_view_profile_content(profile_id)
        AND EXISTS (
            SELECT 1
            FROM public.posts
            WHERE posts.id = post_replies.post_id
              AND public.can_view_profile_content(posts.profile_id)
              AND (
                  posts.is_age_restricted = false
                  OR public.current_user_can_view_age_restricted()
              )
        )
    );

COMMENT ON POLICY "Allow visible profile posts to be read" ON public.posts IS
    'Public, non-age-restricted posts remain readable to anonymous visitors; authentication is required only for writes.';

COMMENT ON POLICY "Visible post replies can be read" ON public.post_replies IS
    'Replies on publicly visible posts remain readable to anonymous visitors regardless of reply entitlement.';
