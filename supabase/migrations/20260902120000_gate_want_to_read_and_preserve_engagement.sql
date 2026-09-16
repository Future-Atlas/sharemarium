-- Subscription-only want-to-read shelves, while retaining post-level
-- engagement history after the reader finishes a book or ends a subscription.

CREATE OR REPLACE FUNCTION public.current_user_can_use_want_to_read()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL
       AND private.profile_has_active_subscription(auth.uid());
$$;

REVOKE ALL ON FUNCTION public.current_user_can_use_want_to_read() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_can_use_want_to_read()
    TO anon, authenticated;

COMMENT ON FUNCTION public.current_user_can_use_want_to_read() IS
    'Returns whether the current user may change their subscription-only want-to-read shelf.';

CREATE OR REPLACE FUNCTION public.profile_can_expose_want_to_read(
    target_profile_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT private.profile_has_active_subscription(target_profile_id)
       AND public.can_view_profile_content(target_profile_id);
$$;

REVOKE ALL ON FUNCTION public.profile_can_expose_want_to_read(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.profile_can_expose_want_to_read(UUID)
    TO anon, authenticated;

-- A locked shelf is not exposed after cancellation, including to its owner.
DROP POLICY IF EXISTS "Visible want-to-read shelves can be read"
    ON public.want_to_read_books;
CREATE POLICY "Active subscriber want-to-read shelves can be read"
    ON public.want_to_read_books FOR SELECT
    USING (
        public.profile_can_expose_want_to_read(profile_id)
    );

-- Completing a book removes it from the reader's own shelf only.  Do not
-- delete post-level want-to-read reactions: their counts and history remain.
CREATE OR REPLACE FUNCTION public.remove_want_to_read_after_read_post()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    DELETE FROM public.want_to_read_books
    WHERE profile_id = NEW.profile_id
      AND book_id = NEW.book_id;

    RETURN NEW;
END;
$$;

-- Override the previous RPC with an entitlement check before any mutation.
CREATE OR REPLACE FUNCTION public.toggle_want_to_read(
    target_book_id TEXT,
    target_book_title TEXT DEFAULT '',
    target_book_author TEXT DEFAULT '',
    target_book_cover_url TEXT DEFAULT '',
    source_post_id UUID DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    actor UUID := auth.uid();
    target_post public.posts%ROWTYPE;
    existing_direct BOOLEAN;
    has_other_post_source BOOLEAN;
BEGIN
    IF actor IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Authentication required';
    END IF;
    IF NOT public.is_profile_active(actor) THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Account is not active';
    END IF;
    IF NOT public.current_user_can_use_want_to_read() THEN
        RETURN 'subscription_required';
    END IF;

    target_book_id := btrim(COALESCE(target_book_id, ''));
    IF target_book_id = '' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Book ID is required';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.posts
        WHERE profile_id = actor AND book_id = target_book_id
    ) OR EXISTS (
        SELECT 1 FROM public.collections
        WHERE profile_id = actor
          AND book_id = target_book_id
          AND status = 'read'
    ) THEN
        RETURN 'already_read';
    END IF;

    IF source_post_id IS NULL THEN
        SELECT saved_directly INTO existing_direct
        FROM public.want_to_read_books
        WHERE profile_id = actor AND book_id = target_book_id;

        IF FOUND THEN
            DELETE FROM public.post_want_to_reads AS engagement
            USING public.posts AS post
            WHERE engagement.post_id = post.id
              AND engagement.profile_id = actor
              AND post.book_id = target_book_id;
            DELETE FROM public.want_to_read_books
            WHERE profile_id = actor AND book_id = target_book_id;
            RETURN 'removed';
        END IF;

        INSERT INTO public.want_to_read_books (
            profile_id, book_id, book_title, book_author, book_cover_url,
            saved_directly, updated_at
        ) VALUES (
            actor, target_book_id,
            left(COALESCE(target_book_title, ''), 500),
            left(COALESCE(target_book_author, ''), 500),
            left(COALESCE(target_book_cover_url, ''), 2000),
            TRUE, timezone('utc'::text, now())
        )
        ON CONFLICT (profile_id, book_id) DO UPDATE
        SET book_title = CASE WHEN EXCLUDED.book_title = '' THEN want_to_read_books.book_title ELSE EXCLUDED.book_title END,
            book_author = CASE WHEN EXCLUDED.book_author = '' THEN want_to_read_books.book_author ELSE EXCLUDED.book_author END,
            book_cover_url = CASE WHEN EXCLUDED.book_cover_url = '' THEN want_to_read_books.book_cover_url ELSE EXCLUDED.book_cover_url END,
            saved_directly = TRUE,
            updated_at = timezone('utc'::text, now());
        RETURN 'added';
    END IF;

    SELECT * INTO target_post FROM public.posts WHERE id = source_post_id;
    IF NOT FOUND
       OR target_post.book_id <> target_book_id
       OR NOT public.can_view_profile_content(target_post.profile_id) THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Post is not available';
    END IF;
    IF target_post.profile_id = actor THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Cannot react to your own post';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.post_want_to_reads
        WHERE post_id = source_post_id AND profile_id = actor
    ) THEN
        DELETE FROM public.post_want_to_reads
        WHERE post_id = source_post_id AND profile_id = actor;

        SELECT COALESCE(saved_directly, FALSE) INTO existing_direct
        FROM public.want_to_read_books
        WHERE profile_id = actor AND book_id = target_book_id;

        SELECT EXISTS (
            SELECT 1
            FROM public.post_want_to_reads AS engagement
            JOIN public.posts AS post ON post.id = engagement.post_id
            WHERE engagement.profile_id = actor AND post.book_id = target_book_id
        ) INTO has_other_post_source;

        IF NOT COALESCE(existing_direct, FALSE) AND NOT has_other_post_source THEN
            DELETE FROM public.want_to_read_books
            WHERE profile_id = actor AND book_id = target_book_id;
        END IF;
        RETURN 'removed';
    END IF;

    INSERT INTO public.post_want_to_reads (post_id, profile_id)
    VALUES (source_post_id, actor);

    INSERT INTO public.want_to_read_books (
        profile_id, book_id, book_title, book_author, book_cover_url,
        saved_directly, updated_at
    ) VALUES (
        actor, target_book_id,
        left(COALESCE(target_book_title, target_post.book_title, ''), 500),
        left(COALESCE(target_book_author, target_post.book_author, ''), 500),
        left(COALESCE(target_book_cover_url, ''), 2000),
        FALSE, timezone('utc'::text, now())
    )
    ON CONFLICT (profile_id, book_id) DO UPDATE
    SET book_title = CASE WHEN EXCLUDED.book_title = '' THEN want_to_read_books.book_title ELSE EXCLUDED.book_title END,
        book_author = CASE WHEN EXCLUDED.book_author = '' THEN want_to_read_books.book_author ELSE EXCLUDED.book_author END,
        book_cover_url = CASE WHEN EXCLUDED.book_cover_url = '' THEN want_to_read_books.book_cover_url ELSE EXCLUDED.book_cover_url END,
        updated_at = timezone('utc'::text, now());
    RETURN 'added';
END;
$$;

-- Notify every post owner whose post received this user's want-to-read
-- reaction for the book when the user subsequently records it as read.
ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_type_check
    CHECK (
        type IN (
            'reaction', 'want_to_read', 'want_to_read_completed', 'follow',
            'follow_request', 'reply', 'new_post'
        )
    );

ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_check1;
ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_check1
    CHECK (
        (
            type IN ('reaction', 'want_to_read', 'want_to_read_completed', 'new_post')
            AND post_id IS NOT NULL
            AND reply_id IS NULL
        )
        OR (
            type = 'reply'
            AND post_id IS NOT NULL
            AND reply_id IS NOT NULL
        )
        OR (
            type IN ('follow', 'follow_request')
            AND post_id IS NULL
            AND reply_id IS NULL
        )
    );

CREATE OR REPLACE FUNCTION public.create_want_to_read_completed_notifications()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.notifications (recipient_id, actor_id, type, post_id)
    SELECT DISTINCT
        source_post.profile_id,
        NEW.profile_id,
        'want_to_read_completed',
        NEW.id
    FROM public.post_want_to_reads AS engagement
    JOIN public.posts AS source_post ON source_post.id = engagement.post_id
    WHERE engagement.profile_id = NEW.profile_id
      AND source_post.book_id = NEW.book_id
      AND source_post.profile_id <> NEW.profile_id
      AND NOT public.is_blocked_between(source_post.profile_id, NEW.profile_id);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS posts_create_want_to_read_completed_notifications
    ON public.posts;
CREATE TRIGGER posts_create_want_to_read_completed_notifications
AFTER INSERT ON public.posts
FOR EACH ROW EXECUTE FUNCTION public.create_want_to_read_completed_notifications();

REVOKE ALL ON FUNCTION public.create_want_to_read_completed_notifications() FROM PUBLIC;

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
              AND private.profile_has_active_subscription(wanted.profile_id)
        );
$$;

REVOKE ALL ON FUNCTION public.get_book_engagement_counts(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_book_engagement_counts(TEXT)
    TO anon, authenticated;

COMMENT ON FUNCTION public.get_book_engagement_counts(TEXT) IS
    'Returns visible read and active want-to-read shelf totals for a book.';
