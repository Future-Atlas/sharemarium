begin;

select no_plan();

select is(
  has_function_privilege(
    'anon',
    'private.favorite_is_effectively_visible(uuid,text)',
    'EXECUTE'
  ),
  false,
  'anonymous users cannot execute the internal retained-favorite helper'
);

select is(
  has_function_privilege(
    'authenticated',
    'private.favorite_is_effectively_visible(uuid,text)',
    'EXECUTE'
  ),
  false,
  'authenticated users cannot execute the internal retained-favorite helper directly'
);

select ok(
  has_function_privilege(
    'service_role',
    'private.favorite_is_effectively_visible(uuid,text)',
    'EXECUTE'
  ),
  'service role may execute the internal retained-favorite helper'
);

select ok(
  has_function_privilege(
    'anon',
    'public.can_view_favorite(uuid,text)',
    'EXECUTE'
  ),
  'anonymous reads use only the safe profile-aware favorite predicate'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.can_view_favorite(uuid,text)',
    'EXECUTE'
  ),
  'authenticated reads use only the safe profile-aware favorite predicate'
);

select * from finish();
rollback;
