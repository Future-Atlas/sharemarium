-- CREATE OR REPLACE on the favorite trigger must not weaken the privilege
-- boundary established by 20260914191000. The trigger calls private
-- subscription helpers whose EXECUTE privilege is intentionally withheld from
-- authenticated clients, so it must continue to execute as its owner.
ALTER FUNCTION public.enforce_favorites_limit() SECURITY DEFINER;
