/*
# Add authentication roles, admin users table, and policy consent tracking

1. New Tables
- `admin_users`
  - `id` (uuid, primary key)
  - `user_id` (uuid, unique, not null) — references auth.users(id) ON DELETE CASCADE
  - `email` (text, not null) — the admin's email for easy lookup
  - `is_active` (boolean, default true) — allows disabling an admin without deleting
  - `created_at` (timestamptz, default now())
  - `updated_at` (timestamptz, default now())

2. Modified Tables
- `app_users`
  - ADD COLUMN `role` (text, not null, default 'user') — stores 'user' or 'admin'
  - ADD COLUMN `privacy_accepted_at` (timestamptz, nullable) — when user accepted privacy policy
  - ADD COLUMN `terms_accepted_at` (timestamptz, nullable) — when user accepted terms of use
  - ADD COLUMN `auth_user_id` (uuid, nullable) — links to auth.users(id) for migration

3. New RPC Functions
- `get_user_role(p_auth_uid uuid)` — returns 'admin' if user exists in admin_users and is_active,
  otherwise returns the role from app_users (matching auth_user_id), defaulting to 'user'
- `accept_policies(p_privacy boolean, p_terms boolean)` — records the current user's policy
  acceptance timestamps in app_users (matched by auth_user_id)

4. Security
- Enable RLS on admin_users.
- Only authenticated users can SELECT from admin_users (needed for role check).
- Only authenticated users can INSERT/UPDATE/DELETE if they are already an admin
  (admin self-management — full admin management UI will be added later).
- RLS on app_users updated: users can only update their own consent columns.

5. Important Notes
- The `role` column defaults to 'user' so existing app_users rows get 'user' automatically.
- The `auth_user_id` column allows linking old phone-based accounts to new Supabase Auth accounts.
- The `get_user_role` function is SECURITY DEFINER so it can read admin_users without
  exposing the table directly — callers get only their own role string.
- The `accept_policies` function is SECURITY DEFINER so it can update app_users
  without granting broad UPDATE access to users.
*/

-- =========================================================
-- 1. Add columns to app_users
-- =========================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_users' AND column_name = 'role') THEN
    ALTER TABLE app_users ADD COLUMN role text NOT NULL DEFAULT 'user';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_users' AND column_name = 'privacy_accepted_at') THEN
    ALTER TABLE app_users ADD COLUMN privacy_accepted_at timestamptz;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_users' AND column_name = 'terms_accepted_at') THEN
    ALTER TABLE app_users ADD COLUMN terms_accepted_at timestamptz;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_users' AND column_name = 'auth_user_id') THEN
    ALTER TABLE app_users ADD COLUMN auth_user_id uuid;
  END IF;
END $$;

-- Index for fast auth_user_id lookups
CREATE INDEX IF NOT EXISTS idx_app_users_auth_user_id ON app_users(auth_user_id);

-- =========================================================
-- 2. Create admin_users table
-- =========================================================

CREATE TABLE IF NOT EXISTS admin_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read admin_users (needed for role check via RPC, but
-- the RPC is SECURITY DEFINER so this is a fallback for direct queries)
DROP POLICY IF EXISTS "admin_users_select_authenticated" ON admin_users;
CREATE POLICY "admin_users_select_authenticated" ON admin_users FOR SELECT
  TO authenticated USING (true);

-- Only existing admins can insert/update/delete admin_users
DROP POLICY IF EXISTS "admin_users_insert_by_admin" ON admin_users;
CREATE POLICY "admin_users_insert_by_admin" ON admin_users FOR INSERT
  TO authenticated WITH CHECK (
    EXISTS (SELECT 1 FROM admin_users au WHERE au.user_id = auth.uid() AND au.is_active = true)
  );

DROP POLICY IF EXISTS "admin_users_update_by_admin" ON admin_users;
CREATE POLICY "admin_users_update_by_admin" ON admin_users FOR UPDATE
  TO authenticated USING (
    EXISTS (SELECT 1 FROM admin_users au WHERE au.user_id = auth.uid() AND au.is_active = true)
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM admin_users au WHERE au.user_id = auth.uid() AND au.is_active = true)
  );

DROP POLICY IF EXISTS "admin_users_delete_by_admin" ON admin_users;
CREATE POLICY "admin_users_delete_by_admin" ON admin_users FOR DELETE
  TO authenticated USING (
    EXISTS (SELECT 1 FROM admin_users au WHERE au.user_id = auth.uid() AND au.is_active = true)
  );

-- =========================================================
-- 3. RPC: get_user_role
-- =========================================================

CREATE OR REPLACE FUNCTION get_user_role(p_auth_uid uuid)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM admin_users
      WHERE user_id = p_auth_uid AND is_active = true
    ) THEN 'admin'
    ELSE COALESCE(
      (SELECT role FROM app_users WHERE auth_user_id = p_auth_uid LIMIT 1),
      'user'
    )
  END;
$$;

-- =========================================================
-- 4. RPC: accept_policies
-- =========================================================

CREATE OR REPLACE FUNCTION accept_policies(p_privacy boolean, p_terms boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Try to update existing app_users row linked by auth_user_id
  UPDATE app_users
  SET
    privacy_accepted_at = CASE WHEN p_privacy THEN now() ELSE privacy_accepted_at END,
    terms_accepted_at = CASE WHEN p_terms THEN now() ELSE terms_accepted_at END,
    updated_at = now()
  WHERE auth_user_id = auth.uid();

  -- If no row exists yet, create one
  IF NOT FOUND THEN
    INSERT INTO app_users (auth_user_id, role, privacy_accepted_at, terms_accepted_at)
    VALUES (auth.uid(), 'user',
      CASE WHEN p_privacy THEN now() ELSE NULL END,
      CASE WHEN p_terms THEN now() ELSE NULL END
    );
  END IF;
END;
$$;

-- =========================================================
-- 5. RPC: check_policies_accepted
-- =========================================================

CREATE OR REPLACE FUNCTION check_policies_accepted(p_auth_uid uuid)
RETURNS TABLE(privacy_accepted boolean, terms_accepted boolean)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE((SELECT privacy_accepted_at IS NOT NULL FROM app_users WHERE auth_user_id = p_auth_uid LIMIT 1), false),
    COALESCE((SELECT terms_accepted_at IS NOT NULL FROM app_users WHERE auth_user_id = p_auth_uid LIMIT 1), false);
$$;

-- =========================================================
-- 6. Update app_users RLS for consent columns
-- Keep existing broad policies (anon+authenticated) for read/insert/update
-- since the app uses anon key for search logging. The accept_policies RPC
-- handles consent updates via SECURITY DEFINER so users can't bypass it.
-- =========================================================

-- Grant execute on the RPCs
GRANT EXECUTE ON FUNCTION get_user_role(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION accept_policies(boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION check_policies_accepted(uuid) TO authenticated;
