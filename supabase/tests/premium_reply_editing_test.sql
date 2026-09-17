begin;

select no_plan();

create or replace function test_reply_edit_auth(
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
  ('7c000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'reply-free@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('7c000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'reply-plus@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('7c000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'reply-premium@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('7c000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'reply-admin-override@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb);

insert into public.profiles (id, username, user_id, bio, is_private)
values
  ('7c000000-0000-4000-8000-000000000001', 'Reply Free', 'reply_free', '', false),
  ('7c000000-0000-4000-8000-000000000002', 'Reply Plus', 'reply_plus', '', false),
  ('7c000000-0000-4000-8000-000000000003', 'Reply Premium', 'reply_premium', '', false),
  ('7c000000-0000-4000-8000-000000000004', 'Reply Admin Override', 'reply_admin_override', '', false);

insert into private.subscription_entitlements (
  profile_id, is_active, plan, billing_status, current_period_end,
  trial_used, updated_at
)
values
  ('7c000000-0000-4000-8000-000000000002', true, 'plus', 'active', now() + interval '30 days', true, now()),
  ('7c000000-0000-4000-8000-000000000003', true, 'premium', 'active', now() + interval '30 days', true, now());

insert into private.reply_entitlements (profile_id, can_reply)
values ('7c000000-0000-4000-8000-000000000004', true)
on conflict (profile_id) do update set can_reply = excluded.can_reply;

insert into public.posts (
  id, profile_id, book_id, rating, comment, book_title, book_author
)
values (
  '7d000000-0000-4000-8000-000000000001',
  '7c000000-0000-4000-8000-000000000001',
  'reply-edit-target-book',
  4,
  'reply edit target',
  'Reply Edit Target',
  'Test Author'
);

insert into public.post_replies (
  id, post_id, profile_id, message, has_spoiler, created_at, updated_at
)
values
  (
    910000000001,
    '7d000000-0000-4000-8000-000000000001',
    '7c000000-0000-4000-8000-000000000002',
    'Plus original reply',
    false,
    now() - interval '10 minutes',
    now() - interval '10 minutes'
  ),
  (
    910000000002,
    '7d000000-0000-4000-8000-000000000001',
    '7c000000-0000-4000-8000-000000000003',
    'Premium original reply',
    false,
    now() - interval '10 minutes',
    now() - interval '10 minutes'
  ),
  (
    910000000003,
    '7d000000-0000-4000-8000-000000000001',
    '7c000000-0000-4000-8000-000000000004',
    'Override original reply',
    false,
    now() - interval '10 minutes',
    now() - interval '10 minutes'
  );

select test_reply_edit_auth('authenticated', '7c000000-0000-4000-8000-000000000002');
select is(public.current_user_reply_tier(), 'plus', 'Plus reply tier is Plus');
select is(public.current_user_can_edit_replies(), false, 'Plus cannot edit replies');
select throws_ok(
  $$select public.update_current_user_post_reply(910000000001, 'Plus edited reply', false)$$,
  '42501',
  'Premium reply editing is required',
  'Plus cannot edit its own existing reply'
);
select throws_ok(
  $$update public.post_replies set message = 'direct update bypass' where id = 910000000001$$,
  '42501',
  'permission denied for table post_replies',
  'Plus cannot bypass the RPC with direct UPDATE'
);
select lives_ok(
  $$delete from public.post_replies where id = 910000000001$$,
  'Plus may still delete its own existing reply'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_reply_edit_auth('authenticated', '7c000000-0000-4000-8000-000000000003');
select is(public.current_user_reply_tier(), 'premium', 'Premium reply tier is Premium');
select is(public.current_user_can_edit_replies(), true, 'Premium may edit replies');
select is(
  public.update_current_user_post_reply(
    910000000002,
    'Premium edited reply',
    true
  ),
  910000000002::bigint,
  'Premium can edit its own reply'
);
select is(
  (select message from public.post_replies where id = 910000000002),
  'Premium edited reply',
  'Premium edit updates the reply body'
);
select is(
  (select has_spoiler from public.post_replies where id = 910000000002),
  true,
  'Premium edit may update the spoiler flag'
);
select ok(
  (
    select updated_at > created_at
    from public.post_replies
    where id = 910000000002
  ),
  'Premium edit advances updated_at beyond created_at'
);
select throws_ok(
  $$select public.update_current_user_post_reply(910000000003, 'edit another user reply', false)$$,
  'P0002',
  'Reply is not available',
  'Premium cannot edit another user reply'
);
select throws_ok(
  $$select public.update_current_user_post_reply(910000000002, 'https://example.com', false)$$,
  '23514',
  null,
  'reply edit still enforces the existing URL prohibition constraint'
);

-- Downgrade the Premium account to Free. Existing reply stays readable and
-- deletable, but editing is immediately disabled.
reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
update private.subscription_entitlements
set plan = 'free',
    is_active = false,
    billing_status = 'canceled',
    updated_at = timezone('utc'::text, now())
where profile_id = '7c000000-0000-4000-8000-000000000003';

select test_reply_edit_auth('authenticated', '7c000000-0000-4000-8000-000000000003');
select is(public.current_user_reply_tier(), 'free', 'downgraded Premium account resolves to Free');
select is(public.current_user_can_edit_replies(), false, 'downgraded account loses reply editing');
select is(
  (select message from public.post_replies where id = 910000000002),
  'Premium edited reply',
  'existing reply remains readable after subscription ends'
);
select throws_ok(
  $$select public.update_current_user_post_reply(910000000002, 'edit after downgrade', false)$$,
  '42501',
  'Premium reply editing is required',
  'editing is blocked immediately after downgrade'
);
select lives_ok(
  $$delete from public.post_replies where id = 910000000002$$,
  'downgraded reply owner may still delete the existing reply'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_reply_edit_auth('authenticated', '7c000000-0000-4000-8000-000000000004');
select is(public.current_user_reply_tier(), 'premium', 'legacy reply entitlement is treated as Premium override');
select is(public.current_user_can_edit_replies(), true, 'legacy full-access override may edit replies');
select is(
  public.update_current_user_post_reply(910000000003, 'Override edited reply', false),
  910000000003::bigint,
  'legacy full-access override can edit its own reply'
);

select is(
  has_table_privilege('authenticated', 'public.post_replies', 'UPDATE'),
  false,
  'authenticated role still has no direct UPDATE privilege on post_replies'
);
select is(
  has_function_privilege(
    'anon',
    'public.update_current_user_post_reply(bigint,text,boolean)',
    'EXECUTE'
  ),
  false,
  'anonymous users cannot call reply editing RPC'
);

select * from finish();
rollback;
