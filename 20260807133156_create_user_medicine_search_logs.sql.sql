/*
# Create user medicine search logs table

## Purpose
Stores a record of every search a user performs on the medicine search screen,
so administrators can analyze search trends, popular queries, and geographic
distribution of searches.

## New Tables
- `user_medicine_search_logs`
  - `id` (uuid, primary key)
  - `account_id` (text, not null) — the user's session identifier
  - `query` (text, not null) — the search term the user entered
  - `results_count` (integer, default 0) — how many results were returned
  - `latitude` (double precision, nullable) — user's location latitude
  - `longitude` (double precision, nullable) — user's location longitude
  - `governorate` (text, nullable) — governorate derived from location (future use)
  - `searched_at` (timestamptz, default now()) — when the search happened
  - `created_at` (timestamptz, default now()) — row creation timestamp

## Security
- RLS enabled on `user_medicine_search_logs`.
- Anon + authenticated can INSERT (users log their own searches without full auth).
- Only authenticated users can SELECT (admin analytics).
- No UPDATE or DELETE policies (logs are append-only).
*/

CREATE TABLE IF NOT EXISTS user_medicine_search_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id text NOT NULL,
  query text NOT NULL,
  results_count integer NOT NULL DEFAULT 0,
  latitude double precision,
  longitude double precision,
  governorate text,
  searched_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE user_medicine_search_logs ENABLE ROW LEVEL SECURITY;

-- Allow anyone (anon + authenticated) to insert search logs
DROP POLICY IF EXISTS "anon_insert_search_logs" ON user_medicine_search_logs;
CREATE POLICY "anon_insert_search_logs" ON user_medicine_search_logs
  FOR INSERT TO anon, authenticated WITH CHECK (true);

-- Allow authenticated users (admin) to read all search logs
DROP POLICY IF EXISTS "authenticated_read_search_logs" ON user_medicine_search_logs;
CREATE POLICY "authenticated_read_search_logs" ON user_medicine_search_logs
  FOR SELECT TO authenticated USING (true);

-- Index for querying by account or by date
CREATE INDEX IF NOT EXISTS idx_user_medicine_search_logs_account
  ON user_medicine_search_logs (account_id);
CREATE INDEX IF NOT EXISTS idx_user_medicine_search_logs_searched_at
  ON user_medicine_search_logs (searched_at DESC);
