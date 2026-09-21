begin;

select no_plan();

insert into auth.users (
  id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
values
  ('7a000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'stripe-one@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('7a000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'stripe-two@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb);

insert into public.profiles (id, username, user_id, bio, is_private)
values
  ('7a000000-0000-4000-8000-000000000001', 'Stripe One', 'stripe_one', '', false),
  ('7a000000-0000-4000-8000-000000000002', 'Stripe Two', 'stripe_two', '', false);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.link_billing_provider_identity(uuid,text,text,text)',
    'EXECUTE'
  ),
  'authenticated users cannot link provider identities'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.billing_profile_for_provider_customer(text,text)',
    'EXECUTE'
  ),
  'anonymous users cannot resolve billing customer mappings'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.link_billing_provider_identity(uuid,text,text,text)',
    'EXECUTE'
  ),
  'service role can link provider identities'
);

set local role service_role;

select is(
  (select effective_plan from public.billing_provider_context(
    '7a000000-0000-4000-8000-000000000001'::uuid,
    'stripe'
  )),
  'free',
  'new profile resolves to Free before provider identity exists'
);
select is(
  (select trial_used from public.billing_provider_context(
    '7a000000-0000-4000-8000-000000000001'::uuid,
    'stripe'
  )),
  false,
  'new profile has not used a trial'
);

select ok(
  public.link_billing_provider_identity(
    '7a000000-0000-4000-8000-000000000001'::uuid,
    'stripe',
    'cus_test_1',
    null
  ),
  'service role can pre-link Stripe customer without granting paid access'
);
select is(
  private.profile_effective_subscription_plan(
    '7a000000-0000-4000-8000-000000000001'::uuid
  ),
  'free',
  'customer link alone never grants subscription access'
);
select is(
  public.billing_profile_for_provider_customer('stripe', 'cus_test_1'),
  '7a000000-0000-4000-8000-000000000001'::uuid,
  'customer mapping resolves to the owning profile'
);

select ok(
  public.link_billing_provider_identity(
    '7a000000-0000-4000-8000-000000000001'::uuid,
    'stripe',
    'cus_test_1',
    'sub_test_1'
  ),
  'subscription id can be linked after Checkout creates it'
);
select is(
  public.billing_profile_for_provider_subscription('stripe', 'sub_test_1'),
  '7a000000-0000-4000-8000-000000000001'::uuid,
  'subscription mapping resolves to the owning profile'
);
select is(
  (select provider_subscription_id from public.billing_provider_context(
    '7a000000-0000-4000-8000-000000000001'::uuid,
    'stripe'
  )),
  'sub_test_1',
  'billing context exposes linked provider subscription id'
);

select throws_ok(
  $$select public.link_billing_provider_identity(
      '7a000000-0000-4000-8000-000000000002'::uuid,
      'stripe', 'cus_test_1', null
    )$$,
  '23505',
  null,
  'provider customer id cannot be shared across profiles'
);
select throws_ok(
  $$select public.link_billing_provider_identity(
      '7a000000-0000-4000-8000-000000000002'::uuid,
      'stripe', 'cus_test_2', 'sub_test_1'
    )$$,
  '23505',
  null,
  'provider subscription id cannot be shared across profiles'
);
select throws_ok(
  $$select public.link_billing_provider_identity(
      '7a000000-0000-4000-8000-000000000001'::uuid,
      'another-provider', 'customer-other', null
    )$$,
  'P0001',
  'billing_provider_mismatch',
  'existing profile cannot silently switch billing providers'
);

reset role;
select * from finish();
rollback;
