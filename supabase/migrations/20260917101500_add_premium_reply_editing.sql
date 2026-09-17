-- Premium-only reply editing.
--
-- Keep direct UPDATE access on post_replies closed. Edits are performed only
-- through a SECURITY DEFINER RPC that verifies ownership and the current reply
-- tier. Plus/Free users keep read/delete access to their existing replies, but
-- cannot edit after a downgrade.

ALTER TABLE public.post_replies
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE;

UPDATE public.post_replies
SET updated_at = created_at
WHERE updated_at IS NULL;

ALTER TABLE public.post_replies
    ALTER COLUMN updated_at SET DEFAULT timezone('utc'::text, now()),
    ALTER COLUMN updated_at SET NOT NULL;

CREATE OR REPLACE FUNCTION public.current_user_can_edit_replies()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL
       AND public.current_user_reply_tier() = 'premium';
$$;

REVOKE ALL ON FUNCTION public.current_user_can_edit_replies() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_can_edit_replies()
    TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.update_current_user_post_reply(
    target_reply BIGINT,
    reply_message TEXT,
    reply_has_spoiler BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    actor UUID := auth.uid();
    updated_reply_id BIGINT;
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

    IF public.current_user_reply_tier() <> 'premium' THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Premium reply editing is required';
    END IF;

    UPDATE public.post_replies AS reply
       SET message = reply_message,
           has_spoiler = COALESCE(reply_has_spoiler, FALSE),
           updated_at = timezone('utc'::text, now())
     WHERE reply.id = target_reply
       AND reply.profile_id = actor
    RETURNING reply.id INTO updated_reply_id;

    IF updated_reply_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P0002',
            MESSAGE = 'Reply is not available';
    END IF;

    RETURN updated_reply_id;
END;
$$;

REVOKE ALL ON FUNCTION public.update_current_user_post_reply(BIGINT, TEXT, BOOLEAN)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_current_user_post_reply(BIGINT, TEXT, BOOLEAN)
    TO authenticated;

-- Preserve the existing privilege boundary explicitly. Application roles must
-- never gain direct UPDATE, otherwise they could bypass the Premium/ownership
-- checks in update_current_user_post_reply().
REVOKE UPDATE ON TABLE public.post_replies FROM PUBLIC, anon, authenticated;

COMMENT ON COLUMN public.post_replies.updated_at IS
    'Last reply content edit timestamp. Equal to created_at until the reply is edited.';
COMMENT ON FUNCTION public.current_user_can_edit_replies() IS
    'True only for the current Premium reply tier, including the legacy administrator full-access override.';
COMMENT ON FUNCTION public.update_current_user_post_reply(BIGINT, TEXT, BOOLEAN) IS
    'Edits an owned reply only while the current reply tier is Premium; direct table UPDATE remains forbidden.';
