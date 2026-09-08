begin;

select no_plan();

create or replace function test_public_access_auth(test_role text, test_uid uuid default null)
returns void
language plpgsql
as $$
begin
  execute format('set local role %I', test_role);
  perform set_config('request.jwt.claim.role', test_role, true);
  perform set_config('request.jwt.claim.sub', coalesce(test_uid::text, ''), true);
end;
$$;

insert into auth.users (id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
values
  ('70000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'public-writer@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('70000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'reply-entitled@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb);

insert into public.profiles (id, username, user_id, bio, is_private)
values
  ('70000000-0000-4000-8000-000000000001', 'Public Writer', 'public_writer', 'writer without reply entitlement', false),
  ('70000000-0000-4000-8000-000000000002', 'Reply User', 'reply_user', 'reply-entitled user', false);

insert into private.reply_entitlements (profile_id, can_reply, granted_at)
values
  ('70000000-0000-4000-8000-000000000001', false, null),
  ('70000000-0000-4000-8000-000000000002', true, now());

select test_public_access_auth('authenticated', '70000000-0000-4000-8000-000000000001');

select is(public.current_user_can_reply(), false, 'authenticated user without reply entitlement cannot create replies');
select lives_ok(
  $$insert into public.posts (id, profile_id, book_id, rating, comment, book_title, book_author)
    values ('71000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001', 'public-access-book', 4, 'public review by a user without reply entitlement', 'Public Access Book', 'Test Author')$$,
  'user without reply entitlement can still create a normal review post'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_public_access_auth('anon');

select results_eq(
  $$select id from public.posts where id = '71000000-0000-4000-8000-000000000001'::uuid$$,
  $$values ('71000000-0000-4000-8000-000000000001'::uuid)$$,
  'anonymous visitor can read a public review without authenticating'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_public_access_auth('authenticated', '70000000-0000-4000-8000-000000000002');

select lives_ok(
  $$select public.create_post_reply('71000000-0000-4000-8000-000000000001'::uuid, 'reply to non-entitled post author', null::bigint, false)$$,
  'reply-entitled user can reply to a post created by a user without reply entitlement'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_public_access_auth('authenticated', '70000000-0000-4000-8000-000000000001');

select results_eq(
  $$select count(*)::bigint from public.post_replies where post_id = '71000000-0000-4000-8000-000000000001'::uuid$$,
  $$values (1::bigint)$$,
  'post author without reply entitlement can read replies received on their post'
);
select throws_ok(
  $$select public.create_post_reply('71000000-0000-4000-8000-000000000001'::uuid, 'not allowed', null::bigint, false)$$,
  '42501',
  'Reply entitlement is required',
  'reply entitlement still gates reply creation only'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_public_access_auth('anon');

select results_eq(
  $$select count(*)::bigint from public.post_replies where post_id = '71000000-0000-4000-8000-000000000001'::uuid$$,
  $$values (1::bigint)$$,
  'anonymous visitor can read replies on a public post without authentication'
);

select * from finish();
rollback;
