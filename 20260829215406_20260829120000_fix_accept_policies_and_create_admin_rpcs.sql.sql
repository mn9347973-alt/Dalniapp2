/*
# Fix accept_policies and create_admin_with_password RPC functions

## Problem 1: accept_policies fails for new users
The `accept_policies` function tries to INSERT into `app_users` when no existing row
matches `auth_user_id`, but `account_id` is `NOT NULL` with no default value.
This causes a constraint violation: "null value in column account_id violates not-null constraint".
The user sees "حدث خطأ أثناء حفظ الموافقة" and stays stuck on the consent screen.

Fix: In the INSERT branch, provide `account_id` using the user's email from `auth.users`.
Also update the UPDATE branch to set `account_id` if it was null.

## Problem 2: create_admin_with_password may fail
The `app_users` INSERT uses `ON CONFLICT DO NOTHING` but the only unique constraint is on
`account_id`, not `auth_user_id`. If a user already has an `app_users` row (e.g. from a
previous phone-based account), a duplicate row with `account_id = email` gets inserted
instead of updating the existing one. Also, if the email already exists as an `account_id`,
the `ON CONFLICT DO NOTHING` silently skips the insert and the subsequent UPDATE by
`auth_user_id` won't find the row.

Fix: Use `ON CONFLICT (account_id) DO UPDATE` to upsert properly, and also update
by `auth_user_id` in case a phone-based row exists.

## Changes
1. Recreate `accept_policies` function — provide `account_id` from user email on INSERT.
2. Recreate `create_admin_with_password` function — fix the `app_users` upsert logic.
*/

-- =========================================================
-- 1. Fix accept_policies: provide account_id on INSERT
-- =========================================================

CREATE OR REPLACE FUNCTION accept_policies(p_privacy boolean, p_terms boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text;
  v_account_id text;
BEGIN
  -- Get the user's email for use as account_id fallback
  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();

  -- Try to update existing app_users row linked by auth_user_id
  UPDATE app_users
  SET
    privacy_accepted_at = CASE WHEN p_privacy THEN now() ELSE privacy_accepted_at END,
    terms_accepted_at = CASE WHEN p_terms THEN now() ELSE terms_accepted_at END,
    updated_at = now()
  WHERE auth_user_id = auth.uid();

  -- If no row exists yet, create one
  IF NOT FOUND THEN
    -- Use email as account_id, or fallback to auth uid as string
    v_account_id := COALESCE(v_email, auth.uid()::text);

    INSERT INTO app_users (account_id, auth_user_id, role, privacy_accepted_at, terms_accepted_at)
    VALUES (v_account_id, auth.uid(), 'user',
      CASE WHEN p_privacy THEN now() ELSE NULL END,
      CASE WHEN p_terms THEN now() ELSE NULL END
    )
    ON CONFLICT (account_id) DO UPDATE SET
      auth_user_id = EXCLUDED.auth_user_id,
      privacy_accepted_at = COALESCE(app_users.privacy_accepted_at, EXCLUDED.privacy_accepted_at),
      terms_accepted_at = COALESCE(app_users.terms_accepted_at, EXCLUDED.terms_accepted_at),
      updated_at = now();
  END IF;
END;
$$;

-- =========================================================
-- 2. Fix create_admin_with_password: proper app_users upsert
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

-- Re-grant execute permissions
GRANT EXECUTE ON FUNCTION accept_policies(boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION create_admin_with_password(text, text, text) TO authenticated;
