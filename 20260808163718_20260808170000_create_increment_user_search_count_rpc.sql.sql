-- Create RPC to increment search_count in app_users
-- Called after each search to track user engagement

CREATE OR REPLACE FUNCTION increment_user_search_count(p_account_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO app_users (account_id, last_active_at, search_count, updated_at)
  VALUES (p_account_id, now(), 1, now())
  ON CONFLICT (account_id) DO UPDATE
  SET search_count = app_users.search_count + 1,
      last_active_at = now(),
      updated_at = now();
END;
$$;

-- Grant execute to anon and authenticated (app uses anon key)
GRANT EXECUTE ON FUNCTION increment_user_search_count(text) TO anon, authenticated;
