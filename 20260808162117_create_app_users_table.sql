/*
# Create app_users table for tracking app users

1. New Tables
- `app_users`
  - `id` (uuid, primary key)
  - `account_id` (text, unique, not null) — the 9-digit phone number used as login
  - `display_name` (text, nullable) — optional display name
  - `last_active_at` (timestamptz) — last time the user was active
  - `search_count` (integer, default 0) — total searches by this user
  - `created_at` (timestamptz, default now())
  - `updated_at` (timestamptz, default now())

2. Security
- Enable RLS on `app_users`.
- Allow anon + authenticated to read (admin dashboard uses anon key).
- Allow anon + authenticated to insert (user login creates a record).
- Allow anon + authenticated to update (updating last_active_at and search_count).

3. Notes
- This table tracks users who log into the app with their phone number.
- The `profiles` table already exists but has no data because nothing creates entries on login.
- This table will be populated by the frontend when a user logs in.
*/

CREATE TABLE IF NOT EXISTS app_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id text UNIQUE NOT NULL,
  display_name text,
  last_active_at timestamptz DEFAULT now(),
  search_count integer NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE app_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "app_users_select_all" ON app_users;
CREATE POLICY "app_users_select_all" ON app_users FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "app_users_insert_all" ON app_users;
CREATE POLICY "app_users_insert_all" ON app_users FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "app_users_update_all" ON app_users;
CREATE POLICY "app_users_update_all" ON app_users FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

-- Create index for fast lookups by account_id
CREATE INDEX IF NOT EXISTS idx_app_users_account_id ON app_users(account_id);
