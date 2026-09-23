/*
# Add admin permissions, password management, and admin roles

1. New Tables
- `admin_permissions`
  - `id` (uuid, primary key)
  - `admin_user_id` (uuid, not null) — references admin_users(id) ON DELETE CASCADE
  - `section` (text, not null) — the main section id (e.g. 'pharmacies', 'medicines', 'app', etc.)
  - `sub_tab` (text, nullable) — the sub-tab id within the section (null = applies to whole section)
  - `access_level` (text, not null) — 'editor' or 'viewer'
  - `created_at` (timestamptz, default now())
  - UNIQUE constraint on (admin_user_id, section, sub_tab) to prevent duplicates

2. Modified Tables
- `admin_users`
  - ADD COLUMN `is_super` (boolean, not null, default false) — super admins bypass all permission checks
  - ADD COLUMN `full_name` (text, nullable) — display name for the admin
  - ADD COLUMN `password_changed_at` (timestamptz, nullable) — tracks last password change

3. New RPC Functions
- `change_admin_password(p_new_password text)` — changes the current authenticated admin's password
  via Supabase Auth admin API. SECURITY DEFINER so it can call auth.users update.
- `get_admin_permissions(p_admin_user_id uuid)` — returns all permission rows for a given admin.
  SECURITY DEFINER so any authenticated admin can read another admin's permissions for management.
- `set_admin_permission(p_admin_user_id uuid, p_section text, p_sub_tab text, p_access_level text)`
  — upserts a permission row for a given admin. Only super admins or existing admins can call this.
  SECURITY DEFINER.
- `remove_admin_permission(p_admin_user_id uuid, p_section text, p_sub_tab text)`
  — removes a permission row. SECURITY DEFINER.
- `get_my_permissions()` — returns the current authenticated admin's permissions as a JSON array.
  SECURITY DEFINER. Used by the frontend to load permissions into session.

4. Security
- Enable RLS on admin_permissions.
- Only authenticated users can SELECT (needed for permission checks via RPC).
- Only super admins or existing admins can INSERT/UPDATE/DELETE.
- The RPC functions are SECURITY DEFINER so they bypass RLS for legitimate operations.

5. Important Notes
- The `is_super` column defaults to false. The initial admin account created earlier
  will be updated to is_super = true via a separate SQL statement.
- Super admins (is_super = true) bypass all permission checks — they see everything as editor.
- Non-super admins see only sections/sub-tabs where they have a permission row.
- Access levels: 'editor' (full CRUD) or 'viewer' (read-only).
- If no permission row exists for a section/sub-tab, the admin cannot see it.
- The `change_admin_password` function uses the Supabase Auth admin API to update
  the user's password directly, requiring the user to be authenticated.
*/

-- =========================================================
-- 1. Add columns to admin_users
-- =========================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name = 'admin_users' AND column_name = 'is_super') THEN
    ALTER TABLE admin_users ADD COLUMN is_super boolean NOT NULL DEFAULT false;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name = 'admin_users' AND column_name = 'full_name') THEN
    ALTER TABLE admin_users ADD COLUMN full_name text;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name = 'admin_users' AND column_name = 'password_changed_at') THEN
    ALTER TABLE admin_users ADD COLUMN password_changed_at timestamptz;
  END IF;
END $$;

-- Set the initial admin as super
UPDATE admin_users SET is_super = true WHERE email = 'hatmalnyby057@gmail.com';

-- =========================================================
-- 2. Create admin_permissions table
-- =========================================================

CREATE TABLE IF NOT EXISTS admin_permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  section text NOT NULL,
  sub_tab text,
  access_level text NOT NULL DEFAULT 'viewer' CHECK (access_level IN ('editor', 'viewer')),
  created_at timestamptz DEFAULT now(),
  UNIQUE (admin_user_id, section, sub_tab)
);

ALTER TABLE admin_permissions ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read permissions (needed for permission checks)
DROP POLICY IF EXISTS "admin_permissions_select_authenticated" ON admin_permissions;
CREATE POLICY "admin_permissions_select_authenticated" ON admin_permissions FOR SELECT
  TO authenticated USING (true);

-- Only super admins or existing admins can insert/update/delete permissions
DROP POLICY IF EXISTS "admin_permissions_insert_by_admin" ON admin_permissions;
CREATE POLICY "admin_permissions_insert_by_admin" ON admin_permissions FOR INSERT
  TO authenticated WITH CHECK (
    EXISTS (SELECT 1 FROM admin_users au WHERE au.user_id = auth.uid() AND au.is_active = true)
  );

DROP POLICY IF EXISTS "admin_permissions_update_by_admin" ON admin_permissions;
CREATE POLICY "admin_permissions_update_by_admin" ON admin_permissions FOR UPDATE
  TO authenticated USING (
    EXISTS (SELECT 1 FROM admin_users au WHERE au.user_id = auth.uid() AND au.is_active = true)
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM admin_users au WHERE au.user_id = auth.uid() AND au.is_active = true)
  );

DROP POLICY IF EXISTS "admin_permissions_delete_by_admin" ON admin_permissions;
CREATE POLICY "admin_permissions_delete_by_admin" ON admin_permissions FOR DELETE
  TO authenticated USING (
    EXISTS (SELECT 1 FROM admin_users au WHERE au.user_id = auth.uid() AND au.is_active = true)
  );

-- =========================================================
-- 3. RPC: change_admin_password
-- =========================================================

CREATE OR REPLACE FUNCTION change_admin_password(p_new_password text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF length(p_new_password) < 6 THEN
    RAISE EXCEPTION 'Password must be at least 6 characters';
  END IF;

  -- Verify the user is an admin
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE user_id = v_user_id AND is_active = true) THEN
    RAISE EXCEPTION 'Not an admin user';
  END IF;

  -- Update the encrypted password in auth.users
  UPDATE auth.users
  SET encrypted_password = crypt(p_new_password, gen_salt('bf')),
      updated_at = now()
  WHERE id = v_user_id;

  -- Record the change timestamp
  UPDATE admin_users
  SET password_changed_at = now(), updated_at = now()
  WHERE user_id = v_user_id;
END;
$$;

-- =========================================================
-- 4. RPC: get_admin_permissions
-- =========================================================

CREATE OR REPLACE FUNCTION get_admin_permissions(p_admin_user_id uuid)
RETURNS TABLE(id uuid, section text, sub_tab text, access_level text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id, section, sub_tab, access_level
  FROM admin_permissions
  WHERE admin_user_id = p_admin_user_id
  ORDER BY section, sub_tab;
$$;

-- =========================================================
-- 5. RPC: set_admin_permission
-- =========================================================

CREATE OR REPLACE FUNCTION set_admin_permission(
  p_admin_user_id uuid,
  p_section text,
  p_sub_tab text,
  p_access_level text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Verify caller is an active admin
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE user_id = auth.uid() AND is_active = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- Verify target is an admin
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = p_admin_user_id AND is_active = true) THEN
    RAISE EXCEPTION 'Target user is not an active admin';
  END IF;

  -- Upsert the permission
  INSERT INTO admin_permissions (admin_user_id, section, sub_tab, access_level)
  VALUES (p_admin_user_id, p_section, p_sub_tab, p_access_level)
  ON CONFLICT (admin_user_id, section, sub_tab)
  DO UPDATE SET access_level = EXCLUDED.access_level;
END;
$$;

-- =========================================================
-- 6. RPC: remove_admin_permission
-- =========================================================

CREATE OR REPLACE FUNCTION remove_admin_permission(
  p_admin_user_id uuid,
  p_section text,
  p_sub_tab text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE user_id = auth.uid() AND is_active = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  DELETE FROM admin_permissions
  WHERE admin_user_id = p_admin_user_id AND section = p_section AND sub_tab IS NOT DISTINCT FROM p_sub_tab;
END;
$$;

-- =========================================================
-- 7. RPC: get_my_permissions
-- Returns the current admin's permissions as a JSON array, plus is_super flag
-- =========================================================

CREATE OR REPLACE FUNCTION get_my_permissions()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result json;
  v_is_super boolean;
BEGIN
  SELECT is_super INTO v_is_super FROM admin_users WHERE user_id = auth.uid() AND is_active = true;
  IF v_is_super IS NULL THEN
    RETURN json_build_object('is_super', false, 'permissions', '[]'::json);
  END IF;

  SELECT COALESCE(json_agg(json_build_object(
    'section', p.section,
    'sub_tab', p.sub_tab,
    'access_level', p.access_level
  )), '[]'::json) INTO v_result
  FROM admin_permissions p
  WHERE p.admin_user_id = (SELECT id FROM admin_users WHERE user_id = auth.uid());

  RETURN json_build_object('is_super', v_is_super, 'permissions', v_result);
END;
$$;

-- =========================================================
-- 8. RPC: create_admin_with_password
-- Creates a new auth user + admin_users entry in one call.
-- Only existing admins can call this.
-- =========================================================

CREATE OR REPLACE FUNCTION create_admin_with_password(
  p_email text,
  p_password text,
  p_full_name text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id uuid;
  v_admin_id uuid;
BEGIN
  -- Verify caller is an admin
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE user_id = auth.uid() AND is_active = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF length(p_password) < 6 THEN
    RAISE EXCEPTION 'Password must be at least 6 characters';
  END IF;

  -- Check if user already exists in auth.users
  SELECT id INTO v_user_id FROM auth.users WHERE email = p_email LIMIT 1;

  IF v_user_id IS NULL THEN
    -- Create new auth user
    v_user_id := gen_random_uuid();
    INSERT INTO auth.users (
      instance_id, id, aud, role, email,
      encrypted_password, email_confirmed_at,
      created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      p_email,
      crypt(p_password, gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}',
      json_build_object('full_name', p_full_name)
    );
  ELSE
    -- User exists, update password
    UPDATE auth.users
    SET encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now()
    WHERE id = v_user_id;
  END IF;

  -- Insert into admin_users
  INSERT INTO admin_users (user_id, email, is_active, full_name, password_changed_at)
  VALUES (v_user_id, p_email, true, p_full_name, now())
  ON CONFLICT (user_id) DO UPDATE SET
    is_active = true,
    full_name = COALESCE(p_full_name, admin_users.full_name),
    password_changed_at = now(),
    updated_at = now()
  RETURNING id INTO v_admin_id;

  -- Ensure app_users role is admin
  INSERT INTO app_users (account_id, auth_user_id, role, privacy_accepted_at, terms_accepted_at)
  VALUES (p_email, v_user_id, 'admin', now(), now())
  ON CONFLICT DO NOTHING;

  UPDATE app_users SET role = 'admin' WHERE auth_user_id = v_user_id;

  RETURN v_admin_id;
END;
$$;

-- =========================================================
-- Grant execute permissions
-- =========================================================

GRANT EXECUTE ON FUNCTION change_admin_password(text) TO authenticated;
GRANT EXECUTE ON FUNCTION get_admin_permissions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION set_admin_permission(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION remove_admin_permission(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION get_my_permissions() TO authenticated;
GRANT EXECUTE ON FUNCTION create_admin_with_password(text, text, text) TO authenticated;
