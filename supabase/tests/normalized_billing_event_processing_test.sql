begin;

select no_plan();

insert into auth.users (
  id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
values
  ('79000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'billing-one@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('79000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'billing-two@example.test', now(), now(), '{}'::jsonb, '{}'::jsonb);

insert into public.profiles (id, username, user_id, bio, is_private)
values
  ('79000000-0000-4000-8000-000000000001', 'Billing One', 'billing_one', '', false),
  ('79000000-0000-4000-8000-000000000002', 'Billing Two', 'billing_two', '', false);

select ok(
  not has_function_privilege(
    'anon',
    'public.claim_billing_webhook_event(text,text,text,text,uuid,text,timestamp with time zone)',
    'EXECUTE'
  ),
  'anonymous users cannot claim billing events'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.apply_normalized_subscription_event(uuid,uuid,text,timestamp with time zone,text,timestamp with time zone,timestamp with time zone,text)',
    'EXECUTE'
  ),
  'authenticated users cannot apply normalized subscription events'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.apply_normalized_charge_event(uuid,uuid,text,text,bigint,text,text,text,text,timestamp with time zone,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ),
  'authenticated users cannot apply normalized charge events'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.apply_normalized_refund_event(uuid,text,text,bigint,text,text,text,timestamp with time zone)',
    'EXECUTE'
  ),
  'authenticated users cannot apply normalized refund events'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.claim_billing_webhook_event(text,text,text,text,uuid,text,timestamp with time zone)',
    'EXECUTE'
  ),
  'service role can claim verified billing events'
);

set local role service_role;

-- First delivery is claimed and a duplicate in-flight delivery is suppressed.
select results_eq(
  $$select should_process from public.claim_billing_webhook_event(
      'testpay', 'evt_trial', 'customer.trial.started', 'subscription.trial_started',
      '79000000-0000-4000-8000-000000000001'::uuid,
      repeat('a', 64), '2030-01-01 00:00:00+00'::timestamptz
    )$$,
  $$values (true)$$,
  'first verified webhook delivery is claimed'
);
select results_eq(
  $$select should_process from public.claim_billing_webhook_event(
      'testpay', 'evt_trial', 'customer.trial.started', 'subscription.trial_started',
      '79000000-0000-4000-8000-000000000001'::uuid,
      repeat('a', 64), '2030-01-01 00:00:00+00'::timestamptz
    )$$,
  $$values (false)$$,
  'concurrent duplicate delivery is not processed twice'
);

select is(
  public.apply_normalized_subscription_event(
    (select id from private.billing_webhook_events where provider = 'testpay' and provider_event_id = 'evt_trial'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    'premium', null, null, null, null, 'cus_1'
  ),
  true,
  'trial-start event applies successfully'
);
select is(
  (select billing_status from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  'trialing',
  'trial-start event sets trialing billing status'
);
select is(
  (select plan from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  'premium',
  'trial-start event activates the selected paid plan'
);
select is(
  (select trial_used from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  true,
  'trial is permanently marked used'
);
select is(
  (select trial_ends_at from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  '2030-01-11 00:00:00+00'::timestamptz,
  'normalized trial duration is exactly ten days'
);
select is(
  (select status from private.billing_webhook_events where provider = 'testpay' and provider_event_id = 'evt_trial'),
  'processed',
  'successfully applied event is marked processed'
);
select results_eq(
  $$select should_process from public.claim_billing_webhook_event(
      'testpay', 'evt_trial', 'customer.trial.started', 'subscription.trial_started',
      '79000000-0000-4000-8000-000000000001'::uuid,
      repeat('a', 64), '2030-01-01 00:00:00+00'::timestamptz
    )$$,
  $$values (false)$$,
  'processed duplicate stays idempotent'
);
select throws_ok(
  $$select * from public.claim_billing_webhook_event(
      'testpay', 'evt_trial', 'customer.trial.started', 'subscription.trial_started',
      '79000000-0000-4000-8000-000000000001'::uuid,
      repeat('b', 64), '2030-01-01 00:00:00+00'::timestamptz
    )$$,
  'P0001',
  'billing_event_identity_mismatch',
  'same provider event id with a different payload hash is rejected'
);

-- Failed and stale processing deliveries can be safely reclaimed.
select results_eq(
  $$select should_process from public.claim_billing_webhook_event(
      'testpay', 'evt_retry', 'unhandled.event', 'ignored',
      '79000000-0000-4000-8000-000000000001'::uuid,
      repeat('c', 64), '2030-01-01 01:00:00+00'::timestamptz
    )$$,
  $$values (true)$$,
  'retry test event is initially claimed'
);
select is(
  public.mark_billing_webhook_event_failed(
    (select id from private.billing_webhook_events where provider = 'testpay' and provider_event_id = 'evt_retry'),
    'temporary provider mapping failure'
  ),
  true,
  'adapter can persist a failed processing result'
);
select results_eq(
  $$select should_process from public.claim_billing_webhook_event(
      'testpay', 'evt_retry', 'unhandled.event', 'ignored',
      '79000000-0000-4000-8000-000000000001'::uuid,
      repeat('c', 64), '2030-01-01 01:00:00+00'::timestamptz
    )$$,
  $$values (true)$$,
  'failed event can be reclaimed for retry'
);
select is(
  (select attempt_count from private.billing_webhook_events where provider = 'testpay' and provider_event_id = 'evt_retry'),
  2,
  'retry increments the attempt counter'
);
select is(
  public.ignore_billing_webhook_event(
    (select id from private.billing_webhook_events where provider = 'testpay' and provider_event_id = 'evt_retry'),
    'provider event intentionally ignored'
  ),
  true,
  'claimed event can be explicitly ignored'
);

select results_eq(
  $$select should_process from public.claim_billing_webhook_event(
      'testpay', 'evt_stale', 'unhandled.stale', 'ignored',
      null::uuid, repeat('d', 64), '2030-01-01 02:00:00+00'::timestamptz
    )$$,
  $$values (true)$$,
  'stale test event is initially claimed'
);
update private.billing_webhook_events
set processing_started_at = timezone('utc'::text, now()) - interval '16 minutes'
where provider = 'testpay' and provider_event_id = 'evt_stale';
select results_eq(
  $$select should_process from public.claim_billing_webhook_event(
      'testpay', 'evt_stale', 'unhandled.stale', 'ignored',
      null::uuid, repeat('d', 64), '2030-01-01 02:00:00+00'::timestamptz
    )$$,
  $$values (true)$$,
  'stale processing lease is reclaimable'
);
select is(
  (select attempt_count from private.billing_webhook_events where provider = 'testpay' and provider_event_id = 'evt_stale'),
  2,
  'stale reclaim increments the attempt counter'
);
select ok(
  public.ignore_billing_webhook_event(
    (select id from private.billing_webhook_events where provider = 'testpay' and provider_event_id = 'evt_stale'),
    'stale retry completed'
  ),
  'stale retry can complete normally'
);

-- Active subscription supersedes the trial state.
select * from public.claim_billing_webhook_event(
  'testpay', 'evt_active', 'subscription.updated', 'subscription.active',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('e', 64), '2030-01-02 00:00:00+00'::timestamptz
);
select ok(
  public.apply_normalized_subscription_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_active'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    'premium', '2030-02-02 00:00:00+00'::timestamptz,
    null, null, null, 'cus_1'
  ),
  'active subscription event applies'
);
select is(
  (select billing_status from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  'active',
  'active event transitions trial to active billing'
);
select is(
  (select current_period_end from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  '2030-02-02 00:00:00+00'::timestamptz,
  'active event stores the paid period end'
);

-- An older failure arriving after a newer active event is ignored.
select * from public.claim_billing_webhook_event(
  'testpay', 'evt_old_failure', 'invoice.failed', 'subscription.payment_failed',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('f', 64), '2030-01-01 12:00:00+00'::timestamptz
);
select is(
  public.apply_normalized_subscription_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_old_failure'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    null, null, null, null, '2030-01-08 12:00:00+00'::timestamptz, 'cus_1'
  ),
  false,
  'older subscription lifecycle event is ignored'
);
select is(
  (select billing_status from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  'active',
  'older payment failure cannot regress active state'
);
select is(
  (select status from private.billing_webhook_events where provider_event_id = 'evt_old_failure'),
  'ignored',
  'out-of-order subscription event is recorded as ignored'
);

-- Newer payment failure starts the seven-day grace period, then recovery clears it.
select * from public.claim_billing_webhook_event(
  'testpay', 'evt_failure', 'invoice.failed', 'subscription.payment_failed',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('1', 64), '2030-01-03 00:00:00+00'::timestamptz
);
select ok(
  public.apply_normalized_subscription_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_failure'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    null, '2030-02-02 00:00:00+00'::timestamptz,
    null, null, '2030-01-10 00:00:00+00'::timestamptz, 'cus_1'
  ),
  'newer payment failure applies'
);
select is(
  (select billing_status from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  'past_due',
  'payment failure marks account past due'
);
select is(
  (select payment_grace_until from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  '2030-01-10 00:00:00+00'::timestamptz,
  'payment failure stores one-week grace deadline supplied by adapter'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_recovered', 'invoice.paid', 'subscription.payment_recovered',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('2', 64), '2030-01-04 00:00:00+00'::timestamptz
);
select ok(
  public.apply_normalized_subscription_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_recovered'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    null, '2030-02-02 00:00:00+00'::timestamptz,
    null, null, null, 'cus_1'
  ),
  'payment recovery applies'
);
select is(
  (select billing_status from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  'active',
  'payment recovery returns account to active'
);
select is(
  (select payment_grace_until from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  null::timestamptz,
  'payment recovery clears grace period'
);

-- Plan changes and cancellations are mutually exclusive scheduled states.
select * from public.claim_billing_webhook_event(
  'testpay', 'evt_plan_schedule', 'subscription.schedule.updated', 'subscription.plan_change_scheduled',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('3', 64), '2030-01-05 00:00:00+00'::timestamptz
);
select ok(
  public.apply_normalized_subscription_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_plan_schedule'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    null, null, 'plus', '2030-02-02 00:00:00+00'::timestamptz,
    null, 'cus_1'
  ),
  'plan change schedule applies'
);
select is(
  (select scheduled_plan from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  'plus',
  'scheduled downgrade is stored'
);
select is(
  (select cancel_at_period_end from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  false,
  'plan change clears any cancellation flag'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_cancel_schedule', 'subscription.cancel.updated', 'subscription.cancel_scheduled',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('4', 64), '2030-01-06 00:00:00+00'::timestamptz
);
select ok(
  public.apply_normalized_subscription_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_cancel_schedule'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    null, '2030-02-02 00:00:00+00'::timestamptz,
    null, null, null, 'cus_1'
  ),
  'cancellation schedule applies'
);
select is(
  (select cancel_at_period_end from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  true,
  'cancellation is scheduled at period end'
);
select is(
  (select scheduled_plan from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  null::text,
  'cancellation clears conflicting scheduled plan change'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_plan_after_cancel', 'subscription.schedule.updated', 'subscription.plan_change_scheduled',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('5', 64), '2030-01-07 00:00:00+00'::timestamptz
);
select ok(
  public.apply_normalized_subscription_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_plan_after_cancel'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    null, null, 'plus', '2030-02-02 00:00:00+00'::timestamptz,
    null, 'cus_1'
  ),
  'new plan schedule can replace cancellation request'
);
select is(
  (select cancel_at_period_end from private.subscription_entitlements where profile_id = '79000000-0000-4000-8000-000000000001'),
  false,
  'plan schedule removes prior cancellation request'
);

-- Trial cannot be consumed a second time even with a different event id.
select * from public.claim_billing_webhook_event(
  'testpay', 'evt_second_trial', 'customer.trial.started', 'subscription.trial_started',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('6', 64), '2030-01-08 00:00:00+00'::timestamptz
);
select throws_ok(
  $$select public.apply_normalized_subscription_event(
      (select id from private.billing_webhook_events where provider_event_id = 'evt_second_trial'),
      '79000000-0000-4000-8000-000000000001'::uuid,
      'premium', null, null, null, null, 'cus_1'
    )$$,
  'P0001',
  'subscription_trial_already_used',
  'one-account trial can only be consumed once across paid plans'
);
select ok(
  public.mark_billing_webhook_event_failed(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_second_trial'),
    'trial already consumed'
  ),
  'failed second-trial event can be recorded for audit'
);

-- Charge events are upserted by immutable provider charge identity.
select * from public.claim_billing_webhook_event(
  'testpay', 'evt_charge_pending', 'charge.pending', 'charge.pending',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('7', 64), '2030-01-10 00:00:00+00'::timestamptz
);
select isnt(
  public.apply_normalized_charge_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_charge_pending'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    'premium', 'monthly', 550, 'JPY', 'ch_1', 'cus_1', 'inv_1',
    null, '2030-01-10 00:00:00+00'::timestamptz, '2030-02-10 00:00:00+00'::timestamptz
  ),
  null::uuid,
  'pending charge event creates a charge row'
);
select is(
  (select status from private.billing_charges where provider = 'testpay' and provider_charge_id = 'ch_1'),
  'pending',
  'charge starts pending'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_charge_paid', 'charge.succeeded', 'charge.paid',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('8', 64), '2030-01-11 00:00:00+00'::timestamptz
);
select isnt(
  public.apply_normalized_charge_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_charge_paid'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    'premium', 'monthly', 550, 'JPY', 'ch_1', 'cus_1', 'inv_1',
    '2030-01-11 00:00:00+00'::timestamptz,
    '2030-01-10 00:00:00+00'::timestamptz, '2030-02-10 00:00:00+00'::timestamptz
  ),
  null::uuid,
  'paid event updates the same charge row'
);
select is(
  (select status from private.billing_charges where provider = 'testpay' and provider_charge_id = 'ch_1'),
  'paid',
  'newer paid event advances charge status'
);
select is(
  (select count(*)::bigint from private.billing_charges where provider = 'testpay' and provider_charge_id = 'ch_1'),
  1::bigint,
  'charge upsert does not duplicate provider charge'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_charge_old_failed', 'charge.failed', 'charge.failed',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('9', 64), '2030-01-10 12:00:00+00'::timestamptz
);
select isnt(
  public.apply_normalized_charge_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_charge_old_failed'),
    '79000000-0000-4000-8000-000000000001'::uuid,
    'premium', 'monthly', 550, 'JPY', 'ch_1', 'cus_1', 'inv_1',
    null, '2030-01-10 00:00:00+00'::timestamptz, '2030-02-10 00:00:00+00'::timestamptz
  ),
  null::uuid,
  'old charge event returns the existing charge id'
);
select is(
  (select status from private.billing_charges where provider = 'testpay' and provider_charge_id = 'ch_1'),
  'paid',
  'older failed event cannot regress a paid charge'
);
select is(
  (select status from private.billing_webhook_events where provider_event_id = 'evt_charge_old_failed'),
  'ignored',
  'older charge event is audited as ignored'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_charge_bad', 'charge.succeeded', 'charge.paid',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('a1', 32), '2030-01-12 00:00:00+00'::timestamptz
);
select throws_ok(
  $$select public.apply_normalized_charge_event(
      (select id from private.billing_webhook_events where provider_event_id = 'evt_charge_bad'),
      '79000000-0000-4000-8000-000000000001'::uuid,
      'premium', 'monthly', 999, 'JPY', 'ch_1', 'cus_1', 'inv_1',
      '2030-01-12 00:00:00+00'::timestamptz,
      '2030-01-10 00:00:00+00'::timestamptz, '2030-02-10 00:00:00+00'::timestamptz
    )$$,
  'P0001',
  'billing_charge_identity_mismatch',
  'same provider charge id cannot silently change immutable amount'
);
select ok(
  public.mark_billing_webhook_event_failed(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_charge_bad'),
    'immutable charge mismatch'
  ),
  'charge identity mismatch remains visible as failed event'
);

-- Refunds reconcile the parent charge and cannot be regressed by older events.
select * from public.claim_billing_webhook_event(
  'testpay', 'evt_refund_pending', 'refund.pending', 'refund.pending',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('b1', 32), '2030-01-13 00:00:00+00'::timestamptz
);
select isnt(
  public.apply_normalized_refund_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_refund_pending'),
    'ch_1', 'ref_1', 200, 'JPY', 'duplicate_charge', 'duplicate portion', null
  ),
  null::uuid,
  'pending refund is recorded'
);
select is(
  (select status from private.billing_charges where provider = 'testpay' and provider_charge_id = 'ch_1'),
  'paid',
  'pending refund does not reduce settled charge status'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_refund_success', 'refund.succeeded', 'refund.succeeded',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('c1', 32), '2030-01-14 00:00:00+00'::timestamptz
);
select isnt(
  public.apply_normalized_refund_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_refund_success'),
    'ch_1', 'ref_1', 200, 'JPY', 'duplicate_charge', 'duplicate portion',
    '2030-01-14 00:00:00+00'::timestamptz
  ),
  null::uuid,
  'refund success updates the existing refund row'
);
select is(
  (select status from private.billing_refunds where provider = 'testpay' and provider_refund_id = 'ref_1'),
  'succeeded',
  'refund becomes succeeded'
);
select is(
  (select status from private.billing_charges where provider = 'testpay' and provider_charge_id = 'ch_1'),
  'partially_refunded',
  'partial succeeded refund updates charge status'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_refund_old_failed', 'refund.failed', 'refund.failed',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('d1', 32), '2030-01-13 12:00:00+00'::timestamptz
);
select isnt(
  public.apply_normalized_refund_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_refund_old_failed'),
    'ch_1', 'ref_1', 200, 'JPY', 'duplicate_charge', null, null
  ),
  null::uuid,
  'older refund event returns existing refund id'
);
select is(
  (select status from private.billing_refunds where provider = 'testpay' and provider_refund_id = 'ref_1'),
  'succeeded',
  'older failed refund cannot regress succeeded refund'
);
select is(
  (select status from private.billing_webhook_events where provider_event_id = 'evt_refund_old_failed'),
  'ignored',
  'older refund event is audited as ignored'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_refund_rest', 'refund.succeeded', 'refund.succeeded',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('e1', 32), '2030-01-15 00:00:00+00'::timestamptz
);
select isnt(
  public.apply_normalized_refund_event(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_refund_rest'),
    'ch_1', 'ref_2', 350, 'JPY', 'other', 'remaining refund',
    '2030-01-15 00:00:00+00'::timestamptz
  ),
  null::uuid,
  'second succeeded refund is recorded'
);
select is(
  (select status from private.billing_charges where provider = 'testpay' and provider_charge_id = 'ch_1'),
  'refunded',
  'full succeeded refund total marks charge refunded'
);

select * from public.claim_billing_webhook_event(
  'testpay', 'evt_refund_over', 'refund.pending', 'refund.pending',
  '79000000-0000-4000-8000-000000000001'::uuid,
  repeat('f1', 32), '2030-01-16 00:00:00+00'::timestamptz
);
select throws_ok(
  $$select public.apply_normalized_refund_event(
      (select id from private.billing_webhook_events where provider_event_id = 'evt_refund_over'),
      'ch_1', 'ref_3', 1, 'JPY', 'other', 'must not exceed original charge', null
    )$$,
  'P0001',
  'refund_amount_exceeds_charge',
  'aggregate pending and succeeded refunds cannot exceed charge amount'
);
select ok(
  public.mark_billing_webhook_event_failed(
    (select id from private.billing_webhook_events where provider_event_id = 'evt_refund_over'),
    'refund would exceed charge amount'
  ),
  'over-refund attempt remains in failed audit state'
);

select is(
  (select count(*)::bigint from private.billing_refunds where provider = 'testpay' and provider_refund_id = 'ref_3'),
  0::bigint,
  'rejected over-refund does not create a refund row'
);

reset role;
select * from finish();
rollback;
