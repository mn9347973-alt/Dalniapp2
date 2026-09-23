/*
# Fix gen_salt/crypt not found in admin RPC functions

## Problem
The `create_admin_with_password` and `change_admin_password` functions use `crypt()` and `gen_salt()`
from the `pgcrypto` extension. On Supabase, these functions live in the `extensions` schema, but
the functions' `search_path` was set to `public, auth` — which does not include `extensions`.
This causes the error: "function gen_salt(unknown) does not exist" when adding a new admin.

## Fix
Add `extensions` to the `search_path` of both functions so PostgreSQL can find `crypt()` and `gen_salt()`.
*/

-- =========================================================
-- 1. Fix create_admin_with_password: add extensions to search_path
-- =========================================================

CREATE OR REPLACE FUNCTION create_admin_with_password(
  p_email text,
  p_password text,
  p_full_name text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
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

  -- Ensure app_users role is admin — upsert by account_id (email)
  INSERT INTO app_users (account_id, auth_user_id, role, privacy_accepted_at, terms_accepted_at)
  VALUES (p_email, v_user_id, 'admin', now(), now())
  ON CONFLICT (account_id) DO UPDATE SET
    auth_user_id = COALESCE(app_users.auth_user_id, EXCLUDED.auth_user_id),
    role = 'admin',
    privacy_accepted_at = COALESCE(app_users.privacy_accepted_at, now()),
    terms_accepted_at = COALESCE(app_users.terms_accepted_at, now()),
    updated_at = now();

  -- Also update any existing row matched by auth_user_id (e.g. phone-based account)
  UPDATE app_users SET role = 'admin', auth_user_id = v_user_id WHERE auth_user_id = v_user_id;

  RETURN v_admin_id;
END;
$$;

-- =========================================================
-- 2. Fix change_admin_password: add extensions to search_path
-- =========================================================

CREATE OR REPLACE FUNCTION change_admin_password(p_new_password text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
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

-- Re-grant execute permissions
GRANT EXECUTE ON FUNCTION create_admin_with_password(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION change_admin_password(text) TO authenticated;
