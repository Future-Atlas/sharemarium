begin;

select no_plan();

create or replace function test_favorite_preference_auth(
  test_role text,
  test_uid uuid default null
)
returns void
language plpgsql
as $$
begin
  execute format('set local role %I', test_role);
  perform set_config('request.jwt.claim.role', test_role, true);
  perform set_config('request.jwt.claim.sub', coalesce(test_uid::text, ''), true);
end;
$$;

insert into auth.users (
  id, aud, role, email, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
values (
  '7a000000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'favorite-preference@example.test',
  now(), now(), '{}'::jsonb, '{}'::jsonb
);

insert into public.profiles (id, username, user_id, bio, is_private)
values (
  '7a000000-0000-4000-8000-000000000001',
  'Favorite Preference', 'favorite_preference', '', false
);

insert into private.subscription_entitlements (
  profile_id,
  is_active,
  plan,
  billing_status,
  current_period_end,
  trial_used,
  updated_at
)
values (
  '7a000000-0000-4000-8000-000000000001',
  true,
  'premium',
  'active',
  now() + interval '30 days',
  true,
  now()
);

insert into public.posts (
  id,
  profile_id,
  book_id,
  rating,
  comment,
  book_title,
  book_author,
  created_at
)
select
  ('7b000000-0000-4000-8000-' || lpad(series::text, 12, '0'))::uuid,
  '7a000000-0000-4000-8000-000000000001'::uuid,
  'preference-book-' || series,
  4,
  'favorite preference test ' || series,
  'Preference Book ' || series,
  'Test Author',
  timezone('utc'::text, now()) - ((6 - series) || ' minutes')::interval
from generate_series(1, 5) as series;

insert into public.favorites (profile_id, book_id, created_at)
select
  '7a000000-0000-4000-8000-000000000001'::uuid,
  'preference-book-' || series,
  timezone('utc'::text, now()) - ((6 - series) || ' minutes')::interval
from generate_series(1, 5) as series;

-- Downgrade from Premium to Free with five retained favorites.
update private.subscription_entitlements
set plan = 'free',
    updated_at = timezone('utc'::text, now())
where profile_id = '7a000000-0000-4000-8000-000000000001';

select test_favorite_preference_auth(
  'authenticated',
  '7a000000-0000-4000-8000-000000000001'
);

select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  true,
  'first Free downgrade requires an explicit three-book selection'
);

select is(
  public.set_current_user_visible_favorites(
    array['preference-book-1', 'preference-book-2', 'preference-book-5']
  ),
  'updated',
  'owner confirms the Free three-book selection'
);

select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  false,
  'confirmed selection resolves the downgrade prompt'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);

select is(
  (
    select selected_limit
    from private.favorite_retention_preferences
    where profile_id = '7a000000-0000-4000-8000-000000000001'
  ),
  3,
  'private preference records the cap for which selection was confirmed'
);

select is(
  has_table_privilege(
    'authenticated',
    'private.favorite_retention_preferences',
    'SELECT'
  ),
  false,
  'authenticated users cannot read the private retention preference table'
);

-- The user intentionally removes one visible favorite later. The limit is a
-- maximum, so two visible favorites must remain valid even though four rows
-- are still retained in total.
select test_favorite_preference_auth(
  'authenticated',
  '7a000000-0000-4000-8000-000000000001'
);

delete from public.favorites
where profile_id = '7a000000-0000-4000-8000-000000000001'
  and book_id = 'preference-book-1';

select is(
  (select total_count from public.current_user_favorite_retention_state()),
  4,
  'removing one chosen favorite leaves four retained rows in total'
);
select is(
  (select effective_visible_count from public.current_user_favorite_retention_state()),
  2,
  'owner may intentionally keep fewer favorites than the Free maximum'
);
select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  false,
  'dropping below the cap after confirmation does not force a new selection'
);
select is(
  (select count(*) from public.favorites),
  2::bigint,
  'ordinary SELECT exposes only the two favorites the user still keeps visible'
);

-- A different cap is a new decision. Moving to Plus with more than twelve
-- retained rows would require a Plus selection, while this small fixture does
-- not because all retained rows fit inside the Plus cap.
reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
update private.subscription_entitlements
set plan = 'plus',
    updated_at = timezone('utc'::text, now())
where profile_id = '7a000000-0000-4000-8000-000000000001';

select test_favorite_preference_auth(
  'authenticated',
  '7a000000-0000-4000-8000-000000000001'
);
select is(
  (select favorite_limit from public.current_user_favorite_retention_state()),
  12,
  'Plus reports its twelve-book cap'
);
select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  false,
  'no Plus selection is needed when all retained rows fit under the new cap'
);

select * from finish();
rollback;
