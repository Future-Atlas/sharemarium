begin;

select no_plan();

create or replace function test_subscription_auth(test_role text, test_uid uuid default null)
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
  ('72000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'free-plan@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('72000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'plus-plan@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('72000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'premium-plan@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('72000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'grace-plan@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('72000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'expired-grace@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('72000000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'scheduled-plan@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb);

insert into public.profiles (id, username, user_id, bio, is_private)
values
  ('72000000-0000-4000-8000-000000000001', 'Free User', 'free_user', '', false),
  ('72000000-0000-4000-8000-000000000002', 'Plus User', 'plus_user', '', false),
  ('72000000-0000-4000-8000-000000000003', 'Premium User', 'premium_user', '', false),
  ('72000000-0000-4000-8000-000000000004', 'Grace User', 'grace_user', '', false),
  ('72000000-0000-4000-8000-000000000005', 'Expired Grace User', 'expired_grace_user', '', false),
  ('72000000-0000-4000-8000-000000000006', 'Scheduled User', 'scheduled_user', '', false);

insert into private.subscription_entitlements (
  profile_id, is_active, plan, billing_status, current_period_end,
  payment_grace_until, scheduled_plan, scheduled_plan_effective_at,
  trial_used, updated_at
)
values
  ('72000000-0000-4000-8000-000000000002', true, 'plus', 'active', now() + interval '30 days', null, null, null, true, now()),
  ('72000000-0000-4000-8000-000000000003', true, 'premium', 'active', now() + interval '30 days', null, null, null, true, now()),
  ('72000000-0000-4000-8000-000000000004', true, 'premium', 'past_due', now() - interval '1 day', now() + interval '6 days', null, null, true, now()),
  ('72000000-0000-4000-8000-000000000005', true, 'premium', 'past_due', now() - interval '8 days', now() - interval '1 day', null, null, true, now()),
  ('72000000-0000-4000-8000-000000000006', true, 'premium', 'active', now(), null, 'plus', now() - interval '1 minute', true, now());

select test_subscription_auth('anon');
select is(public.current_user_subscription_plan(), 'free', 'anonymous users resolve to Free');
select is(public.current_user_has_ad_free_access(), false, 'anonymous users do not get ad-free access');

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_subscription_auth('authenticated', '72000000-0000-4000-8000-000000000001');

select is(public.current_user_subscription_plan(), 'free', 'account without entitlement is Free');
select is(public.current_user_favorite_limit(), 3, 'Free favorite limit is 3');
select is(public.current_user_can_reply(), false, 'Free cannot create replies');
select is(public.current_user_can_use_want_to_read(), false, 'Free cannot use want-to-read shelf');
select is(public.current_user_can_use_all_page_colors(), false, 'Free has only basic page colors');
select is(public.current_user_has_ad_free_access(), false, 'Free is not ad-free');

select lives_ok(
  $$insert into public.posts (id, profile_id, book_id, rating, comment, book_title, book_author)
    values ('73000000-0000-4000-8000-000000000001', '72000000-0000-4000-8000-000000000001', 'subscription-target-book', 4, 'reply target', 'Subscription Target', 'Test Author')$$,
  'Free user can still create an ordinary public post'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_subscription_auth('authenticated', '72000000-0000-4000-8000-000000000002');

select is(public.current_user_subscription_plan(), 'plus', 'Plus resolves as Plus');
select is(public.current_user_favorite_limit(), 12, 'Plus favorite limit is 12');
select is(public.current_user_can_reply(), true, 'Plus may create a limited reply');
select is(public.current_user_can_use_want_to_read(), false, 'Plus cannot use Premium want-to-read shelf');
select is(public.current_user_can_use_all_page_colors(), false, 'Plus cannot use Premium page colors');
select is(public.current_user_has_ad_free_access(), true, 'Plus is ad-free');

select lives_ok(
  $$select public.create_post_reply('73000000-0000-4000-8000-000000000001'::uuid, 'first Plus reply', null::bigint, false)$$,
  'Plus may create one top-level reply on another user post'
);
select throws_ok(
  $$select public.create_post_reply('73000000-0000-4000-8000-000000000001'::uuid, 'second Plus reply', null::bigint, false)$$,
  '42501',
  'Plus allows one top-level reply per post',
  'Plus cannot create a second top-level reply on the same post'
);
select throws_ok(
  $$select public.create_post_reply(
      '73000000-0000-4000-8000-000000000001'::uuid,
      'nested Plus reply',
      (select min(id) from public.post_replies where post_id = '73000000-0000-4000-8000-000000000001'::uuid),
      false
    )$$,
  '42501',
  'Plus does not allow replies to replies',
  'Plus cannot reply to a reply'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_subscription_auth('authenticated', '72000000-0000-4000-8000-000000000003');

select is(public.current_user_subscription_plan(), 'premium', 'Premium resolves as Premium');
select is(public.current_user_favorite_limit(), 2147483647, 'Premium uses the unlimited favorite sentinel');
select is(public.current_user_can_reply(), true, 'Premium may create replies');
select is(public.current_user_can_use_want_to_read(), true, 'Premium may use want-to-read shelf');
select is(public.current_user_can_use_all_page_colors(), true, 'Premium may use all page colors');
select is(public.current_user_has_ad_free_access(), true, 'Premium is ad-free');

select lives_ok(
  $$select public.create_post_reply(
      '73000000-0000-4000-8000-000000000001'::uuid,
      'nested Premium reply',
      (select min(id) from public.post_replies where post_id = '73000000-0000-4000-8000-000000000001'::uuid),
      false
    )$$,
  'Premium may reply to an existing reply'
);
select lives_ok(
  $$select public.create_post_reply('73000000-0000-4000-8000-000000000001'::uuid, 'another Premium reply', null::bigint, false)$$,
  'Premium may create multiple replies'
);

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_subscription_auth('authenticated', '72000000-0000-4000-8000-000000000004');
select is(public.current_user_subscription_plan(), 'premium', 'past-due account remains Premium inside payment grace period');

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_subscription_auth('authenticated', '72000000-0000-4000-8000-000000000005');
select is(public.current_user_subscription_plan(), 'free', 'past-due account becomes Free after payment grace expires');

reset role;
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.sub', '', true);
select test_subscription_auth('authenticated', '72000000-0000-4000-8000-000000000006');
select is(public.current_user_subscription_plan(), 'plus', 'scheduled plan becomes effective at its configured date');
select is(
  (select effective_plan from public.current_user_subscription_state()),
  'plus',
  'subscription state exposes the effective scheduled plan'
);
select is(
  (select scheduled_plan from public.current_user_subscription_state()),
  'plus',
  'subscription state exposes the configured next plan'
);
select is(
  (select trial_used from public.current_user_subscription_state()),
  true,
  'subscription state preserves one-time trial usage'
);

select * from finish();
rollback;
