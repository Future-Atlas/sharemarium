begin;

select no_plan();

select is(
  has_table_privilege('anon', 'private.billing_webhook_events', 'SELECT'),
  false,
  'anonymous users cannot read billing webhook events'
);
select is(
  has_table_privilege('authenticated', 'private.billing_charges', 'SELECT'),
  false,
  'authenticated users cannot read private billing charges directly'
);
select is(
  has_table_privilege('authenticated', 'private.billing_refunds', 'INSERT'),
  false,
  'authenticated users cannot create refunds directly'
);
select ok(
  has_table_privilege('service_role', 'private.billing_webhook_events', 'INSERT'),
  'service role can record billing webhook events'
);
select ok(
  has_table_privilege('service_role', 'private.billing_charges', 'INSERT'),
  'service role can record billing charges'
);
select ok(
  has_table_privilege('service_role', 'private.billing_refunds', 'INSERT'),
  'service role can record billing refunds'
);

set local role service_role;

select lives_ok(
  $$
    insert into private.billing_webhook_events (
      provider,
      provider_event_id,
      event_type,
      payload_sha256
    ) values (
      'testpay',
      'evt_billing_001',
      'invoice.paid',
      repeat('a', 64)
    )
  $$,
  'service role can record the first webhook event'
);

select lives_ok(
  $$
    insert into private.billing_webhook_events (
      provider,
      provider_event_id,
      event_type,
      payload_sha256
    ) values (
      'testpay',
      'evt_billing_001',
      'invoice.paid',
      repeat('a', 64)
    )
    on conflict (provider, provider_event_id) do nothing
  $$,
  'duplicate webhook delivery can be ignored atomically'
);

reset role;

select is(
  (
    select count(*)
    from private.billing_webhook_events
    where provider = 'testpay'
      and provider_event_id = 'evt_billing_001'
  ),
  1::bigint,
  'provider event ID uniqueness keeps webhook processing idempotent'
);

set local role service_role;

select lives_ok(
  $$
    insert into private.billing_charges (
      id,
      provider,
      provider_customer_id,
      provider_charge_id,
      provider_invoice_id,
      plan,
      billing_period,
      amount_minor,
      currency,
      status,
      charged_at,
      period_start,
      period_end
    ) values (
      '74000000-0000-4000-8000-000000000001',
      'testpay',
      'cus_001',
      'charge_001',
      'invoice_001',
      'plus',
      'monthly',
      1000,
      'JPY',
      'paid',
      now(),
      now(),
      now() + interval '30 days'
    )
  $$,
  'service role can record a paid charge without card data'
);

select lives_ok(
  $$
    insert into private.billing_refunds (
      id,
      charge_id,
      provider,
      provider_refund_id,
      amount_minor,
      currency,
      reason_code,
      status
    ) values (
      '75000000-0000-4000-8000-000000000001',
      '74000000-0000-4000-8000-000000000001',
      'testpay',
      'refund_001',
      600,
      'JPY',
      'outage',
      'succeeded'
    )
  $$,
  'a partial refund can be recorded'
);

select throws_ok(
  $$
    insert into private.billing_refunds (
      charge_id,
      provider,
      provider_refund_id,
      amount_minor,
      currency,
      reason_code,
      status
    ) values (
      '74000000-0000-4000-8000-000000000001',
      'testpay',
      'refund_too_large',
      500,
      'JPY',
      'other',
      'pending'
    )
  $$,
  'P0001',
  'refund_amount_exceeds_charge',
  'active refunds cannot exceed the original charge amount'
);

select throws_ok(
  $$
    insert into private.billing_refunds (
      charge_id,
      provider,
      provider_refund_id,
      amount_minor,
      currency,
      reason_code,
      status
    ) values (
      '74000000-0000-4000-8000-000000000001',
      'otherpay',
      'refund_wrong_provider',
      100,
      'JPY',
      'other',
      'pending'
    )
  $$,
  'P0001',
  'refund_provider_mismatch',
  'refund provider must match the original charge'
);

select throws_ok(
  $$
    insert into private.billing_refunds (
      charge_id,
      provider,
      provider_refund_id,
      amount_minor,
      currency,
      reason_code,
      status
    ) values (
      '74000000-0000-4000-8000-000000000001',
      'testpay',
      'refund_wrong_currency',
      100,
      'USD',
      'other',
      'pending'
    )
  $$,
  'P0001',
  'refund_currency_mismatch',
  'refund currency must match the original charge'
);

select lives_ok(
  $$
    insert into private.billing_refunds (
      charge_id,
      provider,
      provider_refund_id,
      amount_minor,
      currency,
      reason_code,
      status
    ) values (
      '74000000-0000-4000-8000-000000000001',
      'testpay',
      'refund_failed_attempt',
      500,
      'JPY',
      'other',
      'failed'
    )
  $$,
  'failed refund attempts do not reserve refundable value'
);

select lives_ok(
  $$
    insert into private.billing_refunds (
      charge_id,
      provider,
      provider_refund_id,
      amount_minor,
      currency,
      reason_code,
      status
    ) values (
      '74000000-0000-4000-8000-000000000001',
      'testpay',
      'refund_002',
      400,
      'JPY',
      'other',
      'pending'
    )
  $$,
  'refunds may exactly reach the original charge amount'
);

reset role;

select is(
  (
    select sum(amount_minor)
    from private.billing_refunds
    where charge_id = '74000000-0000-4000-8000-000000000001'
      and status in ('pending', 'succeeded')
  ),
  1000::bigint,
  'active refund total is capped at the original charge amount'
);

select * from finish();
rollback;
