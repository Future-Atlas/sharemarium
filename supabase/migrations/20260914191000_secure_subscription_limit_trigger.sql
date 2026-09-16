-- The favorites limit trigger calls private subscription helpers. Execute it as
-- its owner so authenticated table writes do not need EXECUTE on private
-- lifecycle functions.
ALTER FUNCTION public.enforce_favorites_limit() SECURITY DEFINER;
