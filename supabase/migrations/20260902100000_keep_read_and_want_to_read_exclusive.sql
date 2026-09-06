-- A book cannot be both read and in a user's want-to-read list.
-- Keep this rule in the database so every client and future write path follows it.

CREATE OR REPLACE FUNCTION public.remove_want_to_read_after_read_post()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.post_want_to_reads AS engagement
    USING public.posts AS source_post
    WHERE engagement.post_id = source_post.id
      AND engagement.profile_id = NEW.profile_id
      AND source_post.book_id = NEW.book_id;

    DELETE FROM public.want_to_read_books
    WHERE profile_id = NEW.profile_id
      AND book_id = NEW.book_id;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS posts_remove_want_to_read_after_insert ON public.posts;
CREATE TRIGGER posts_remove_want_to_read_after_insert
AFTER INSERT ON public.posts
FOR EACH ROW EXECUTE FUNCTION public.remove_want_to_read_after_read_post();

REVOKE ALL ON FUNCTION public.remove_want_to_read_after_read_post() FROM PUBLIC;

-- Clean up any conflicting records created before this restriction.
DELETE FROM public.post_want_to_reads AS engagement
USING public.posts AS source_post
WHERE engagement.post_id = source_post.id
  AND EXISTS (
      SELECT 1
      FROM public.posts AS read_post
      WHERE read_post.profile_id = engagement.profile_id
        AND read_post.book_id = source_post.book_id
  );

DELETE FROM public.want_to_read_books AS wanted
WHERE EXISTS (
        SELECT 1
        FROM public.posts AS read_post
        WHERE read_post.profile_id = wanted.profile_id
          AND read_post.book_id = wanted.book_id
      )
   OR EXISTS (
        SELECT 1
        FROM public.collections AS collection
        WHERE collection.profile_id = wanted.profile_id
          AND collection.book_id = wanted.book_id
          AND collection.status = 'read'
      );

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

REVOKE ALL ON FUNCTION public.toggle_want_to_read(TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_want_to_read(TEXT, TEXT, TEXT, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION public.remove_want_to_read_after_read_post() IS
    'Removes a book from a user''s want-to-read list when they post it as read.';
