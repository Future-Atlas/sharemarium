begin;

select no_plan();

select ok(
  coalesce(
    (
      select pg_get_constraintdef(oid) like '%billing%'
      from pg_constraint
      where conrelid = 'public.contact_requests'::regclass
        and conname = 'contact_requests_category_check'
    ),
    false
  ),
  'contact request category constraint includes billing'
);

select ok(
  coalesce(
    (
      select pg_get_constraintdef(oid) like '%fraud%'
      from pg_constraint
      where conrelid = 'public.contact_requests'::regclass
        and conname = 'contact_requests_category_check'
    ),
    false
  ),
  'contact request category constraint includes fraud'
);

set local role anon;

select lives_ok(
  $$
    insert into public.contact_requests (email, category, subject, message)
    values ('billing@example.test', 'billing', 'Billing question', 'Please review this billing inquiry.')
  $$,
  'anonymous users can submit billing inquiries'
);

select lives_ok(
  $$
    insert into public.contact_requests (email, category, subject, message)
    values ('fraud@example.test', 'fraud', 'Fraud question', 'Please review this unauthorized-use inquiry.')
  $$,
  'anonymous users can submit fraud inquiries'
);

reset role;

select * from finish();
rollback;
