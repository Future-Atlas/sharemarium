begin;

select no_plan();

create or replace function test_favorite_retention_auth(
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
    '76000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'favorite-owner@example.test',
    now(), now(), '{}'::jsonb, '{}'::jsonb
  ),
  (
    '76000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'favorite-viewer@example.test',
    now(), now(), '{}'::jsonb, '{}'::jsonb
  );

insert into public.profiles (id, username, user_id, bio, is_private)
values
  (
    '76000000-0000-4000-8000-000000000001',
    'Favorite Owner', 'favorite_owner', '', false
  ),
  (
    '76000000-0000-4000-8000-000000000002',
    'Favorite Viewer', 'favorite_viewer', '', false
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
  '76000000-0000-4000-8000-000000000001',
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
  ('77000000-0000-4000-8000-' || lpad(series::text, 12, '0'))::uuid,
  '76000000-0000-4000-8000-000000000001'::uuid,
  'retained-book-' || series,
  4,
  'favorite retention test ' || series,
  'Retained Book ' || series,
  'Test Author',
  timezone('utc'::text, now()) - ((6 - series) || ' minutes')::interval
from generate_series(1, 6) as series;

-- Start with five Premium favorites. The sixth posted book is reserved for a
-- later replacement test.
insert into public.favorites (profile_id, book_id, created_at)
select
  '76000000-0000-4000-8000-000000000001'::uuid,
  'retained-book-' || series,
  timezone('utc'::text, now()) - ((6 - series) || ' minutes')::interval
from generate_series(1, 5) as series;

select test_favorite_retention_auth(
  'authenticated',
  '76000000-0000-4000-8000-000000000001'
);

select is(
  (select effective_plan from public.current_user_favorite_retention_state()),
  'premium',
  'Premium retention state reports Premium'
);
select is(
  (select total_count from public.current_user_favorite_retention_state()),
  5,
  'Premium retention state keeps all five favorites'
);
select is(
  (select effective_visible_count from public.current_user_favorite_retention_state()),
  5,
  'Premium exposes every retained favorite'
);
select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  false,
  'Premium never requires a capped favorite selection'
);
select is(
  (select count(*) from public.favorites),
  5::bigint,
  'Premium owner can read every retained favorite'
);

-- Simulate Premium -> Free at renewal. No favorite row is deleted.
reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
update private.subscription_entitlements
set plan = 'free',
    scheduled_plan = null,
    scheduled_plan_effective_at = null,
    updated_at = timezone('utc'::text, now())
where profile_id = '76000000-0000-4000-8000-000000000001';

select test_favorite_retention_auth(
  'authenticated',
  '76000000-0000-4000-8000-000000000001'
);

select is(public.current_user_subscription_plan(), 'free', 'owner is now Free');
select is(
  (select total_count from public.current_user_favorite_retention_state()),
  5,
  'downgrade preserves all favorite rows'
);
select is(
  (select favorite_limit from public.current_user_favorite_retention_state()),
  3,
  'Free retention limit is three'
);
select is(
  (select effective_visible_count from public.current_user_favorite_retention_state()),
  3,
  'before selection only the deterministic Free-sized subset is exposed'
);
select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  true,
  'downgrade asks the owner to choose the three visible favorites'
);
select is(
  (select count(*) from public.favorites),
  3::bigint,
  'ordinary owner SELECT is capped and cannot leak hidden retained favorites'
);
select results_eq(
  $$select book_id from public.favorites order by book_id$$,
  $$values ('retained-book-3'::text), ('retained-book-4'::text), ('retained-book-5'::text)$$,
  'temporary default uses the newest three favorites'
);
select is(
  (select count(*) from public.current_user_favorite_retention_candidates()),
  5::bigint,
  'management RPC returns all retained favorites to the owner'
);
select is(
  (
    select count(*)
    from public.current_user_favorite_retention_candidates()
    where is_selected
  ),
  3::bigint,
  'candidate RPC marks the temporary visible subset as selected'
);

select throws_ok(
  $$select public.set_current_user_visible_favorites(array['retained-book-1', 'retained-book-2'])$$,
  '22023',
  'favorite_selection_count_mismatch',
  'Free owner must choose exactly three favorites when retained rows exceed the limit'
);
select throws_ok(
  $$select public.set_current_user_visible_favorites(array['retained-book-1', 'retained-book-2', 'missing-book'])$$,
  '22023',
  'favorite_selection_contains_unknown_book',
  'favorite selection rejects books not owned by the current profile'
);
select is(
  public.set_current_user_visible_favorites(
    array['retained-book-1', 'retained-book-2', 'retained-book-5']
  ),
  'updated',
  'owner can choose the exact three favorites that remain visible'
);
select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  false,
  'valid selection resolves the downgrade retention prompt'
);
select results_eq(
  $$select book_id from public.favorites order by book_id$$,
  $$values ('retained-book-1'::text), ('retained-book-2'::text), ('retained-book-5'::text)$$,
  'ordinary SELECT exposes exactly the chosen Free favorites'
);

-- A different authenticated user and an anonymous viewer only see the same
-- effective public subset, never the hidden retained rows.
reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_favorite_retention_auth(
  'authenticated',
  '76000000-0000-4000-8000-000000000002'
);
select is(
  (
    select count(*)
    from public.favorites
    where profile_id = '76000000-0000-4000-8000-000000000001'
  ),
  3::bigint,
  'another authenticated viewer sees only the chosen public favorites'
);
select is(
  has_function_privilege(
    'anon',
    'public.current_user_favorite_retention_candidates()',
    'EXECUTE'
  ),
  false,
  'anonymous users cannot call the hidden favorite management RPC'
);
select is(
  has_function_privilege(
    'anon',
    'public.set_current_user_visible_favorites(text[])',
    'EXECUTE'
  ),
  false,
  'anonymous users cannot change favorite visibility'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_favorite_retention_auth('anon');
select is(
  (
    select count(*)
    from public.favorites
    where profile_id = '76000000-0000-4000-8000-000000000001'
  ),
  3::bigint,
  'anonymous viewer sees only the chosen favorites on a public profile'
);

-- Upgrade restores every retained row automatically without rewriting the
-- stored selection.
reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
update private.subscription_entitlements
set plan = 'premium',
    updated_at = timezone('utc'::text, now())
where profile_id = '76000000-0000-4000-8000-000000000001';

select test_favorite_retention_auth(
  'authenticated',
  '76000000-0000-4000-8000-000000000001'
);
select is(
  (select count(*) from public.favorites),
  5::bigint,
  'Premium upgrade automatically restores all retained favorites'
);
select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  false,
  'Premium restoration needs no manual selection'
);

-- Downgrading again remembers the previously chosen Free subset.
reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
update private.subscription_entitlements
set plan = 'free',
    updated_at = timezone('utc'::text, now())
where profile_id = '76000000-0000-4000-8000-000000000001';

select test_favorite_retention_auth(
  'authenticated',
  '76000000-0000-4000-8000-000000000001'
);
select is(
  (select selection_required from public.current_user_favorite_retention_state()),
  false,
  'returning to Free reuses the previous three-book selection'
);
select results_eq(
  $$select book_id from public.favorites order by book_id$$,
  $$values ('retained-book-1'::text), ('retained-book-2'::text), ('retained-book-5'::text)$$,
  'previously chosen Free subset is restored after a later downgrade'
);

-- Existing replacement UX can replace a visible favorite with a retained
-- hidden book without violating the favorites primary key.
select is(
  public.replace_current_user_favorite('retained-book-1', 'retained-book-3'),
  'replaced',
  'replacement can restore a retained hidden favorite'
);
select results_eq(
  $$select book_id from public.favorites order by book_id$$,
  $$values ('retained-book-2'::text), ('retained-book-3'::text), ('retained-book-5'::text)$$,
  'restored hidden favorite takes the released visible slot'
);

-- Replacing with a truly new completed book also works even while another
-- retained favorite stays hidden.
select is(
  public.replace_current_user_favorite('retained-book-2', 'retained-book-6'),
  'replaced',
  'replacement can add a new completed favorite while hidden rows are retained'
);
select results_eq(
  $$select book_id from public.favorites order by book_id$$,
  $$values ('retained-book-3'::text), ('retained-book-5'::text), ('retained-book-6'::text)$$,
  'new favorite fills the released Free slot without exposing hidden retained rows'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select is(
  (
    select count(*)
    from public.favorites
    where profile_id = '76000000-0000-4000-8000-000000000001'
  ),
  4::bigint,
  'replacement deletes only the explicitly replaced favorite while other hidden retained rows stay stored'
);
select is(
  (
    select count(*)
    from public.favorites
    where profile_id = '76000000-0000-4000-8000-000000000001'
      and is_visible = false
  ),
  1::bigint,
  'one retained hidden favorite remains stored after replacements'
);

select * from finish();
rollback;
