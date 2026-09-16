begin;

select no_plan();

create or replace function test_premium_favorite_auth(
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
values
  (
    '78000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'premium-favorite@example.test',
    now(), now(), '{}'::jsonb, '{}'::jsonb
  ),
  (
    '78000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'free-favorite@example.test',
    now(), now(), '{}'::jsonb, '{}'::jsonb
  );

insert into public.profiles (id, username, user_id, bio, is_private)
values
  (
    '78000000-0000-4000-8000-000000000001',
    'Premium Favorite', 'premium_favorite', '', false
  ),
  (
    '78000000-0000-4000-8000-000000000002',
    'Free Favorite', 'free_favorite', '', false
  );

insert into private.subscription_entitlements (
  profile_id, is_active, plan, billing_status, current_period_end,
  trial_used, updated_at
)
values (
  '78000000-0000-4000-8000-000000000001',
  true, 'premium', 'active', now() + interval '30 days', true, now()
);

insert into public.posts (
  id, profile_id, book_id, rating, comment, book_title, book_author
)
select
  ('79000000-0000-4000-8000-' || lpad(series::text, 12, '0'))::uuid,
  '78000000-0000-4000-8000-000000000001'::uuid,
  'premium-favorite-book-' || series,
  4,
  'premium favorite ' || series,
  'Premium Favorite ' || series,
  'Test Author'
from generate_series(1, 5) as series;

insert into public.posts (
  id, profile_id, book_id, rating, comment, book_title, book_author
)
values (
  '79000000-0000-4000-8000-000000000100',
  '78000000-0000-4000-8000-000000000002',
  'free-favorite-book',
  4,
  'free favorite',
  'Free Favorite',
  'Test Author'
);

insert into public.favorites (profile_id, book_id)
select
  '78000000-0000-4000-8000-000000000001'::uuid,
  'premium-favorite-book-' || series
from generate_series(1, 3) as series;

select test_premium_favorite_auth(
  'authenticated',
  '78000000-0000-4000-8000-000000000001'
);

select is(public.current_user_subscription_plan(), 'premium', 'test account is Premium');
select is(public.current_user_favorite_limit(), 2147483647, 'Premium database limit remains unlimited');
select is(
  public.add_current_user_premium_favorite('premium-favorite-book-4'),
  'added',
  'Premium compatibility RPC adds a fourth favorite past the legacy client precheck'
);
select is(
  public.add_current_user_premium_favorite('premium-favorite-book-5'),
  'added',
  'Premium compatibility RPC continues adding favorites without a finite cap'
);
select is(
  (select count(*) from public.favorites),
  5::bigint,
  'Premium owner can read all five favorites after compatibility inserts'
);
select is(
  public.add_current_user_premium_favorite('premium-favorite-book-5'),
  'already_favorited',
  'Premium compatibility RPC is idempotent for an existing favorite'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_premium_favorite_auth(
  'authenticated',
  '78000000-0000-4000-8000-000000000002'
);

select throws_ok(
  $$select public.add_current_user_premium_favorite('free-favorite-book')$$,
  '42501',
  'premium_subscription_required',
  'Free accounts cannot use the Premium compatibility insert RPC'
);
select is(
  has_function_privilege(
    'anon',
    'public.add_current_user_premium_favorite(text)',
    'EXECUTE'
  ),
  false,
  'anonymous users cannot call the Premium favorite RPC'
);

select * from finish();
rollback;
