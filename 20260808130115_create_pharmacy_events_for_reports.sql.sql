/*
# Create pharmacy_events table for report event tracking

## Purpose
Tracks three types of events that are NOT currently logged anywhere:
1. Pharmacy appearance in search results (when a pharmacy shows up in a user's search)
2. Pharmacy detail view (when a user opens the pharmacy details card)
3. Pharmacy call click (when a user clicks the call/whatsapp button)

These events are needed for the Reports Center to show:
- "مرات ظهور الصيدلية في نتائج البحث" (search appearances)
- "عدد زيارات الصيدلية" (detail views)
- "عدد مرات النقر على الاتصال" (call clicks)

## Existing tables reused (NOT duplicated):
- `user_medicine_search_logs` — already logs search queries, results_count, location. NOT touched.
- `pharmacies.profile_views` and `pharmacies.search_count` — existing counter columns on pharmacies table.
  These are denormalized counters. The new `pharmacy_events` table provides the per-event audit trail
  that those counters cannot (no timestamp, no location, no query association).
  The counters will continue to be maintained separately; this table does NOT replace them.

## New Table
- `pharmacy_events`
  - `id` (uuid, PK)
  - `pharmacy_id` (uuid, FK → pharmacies.id ON DELETE CASCADE)
  - `event_type` (text — 'search_appearance' | 'detail_view' | 'call_click')
  - `account_id` (text — the user's session account ID, nullable for anonymity)
  - `search_query` (text — the query that triggered the appearance, nullable for detail_view/call_click)
  - `latitude` (double precision, nullable)
  - `longitude` (double precision, nullable)
  - `governorate` (text, nullable — derived from pharmacy's governorate for geographic reports)
  - `city` (text, nullable — derived from pharmacy's city)
  - `created_at` (timestamptz, default now())

## Security
- RLS enabled.
- anon + authenticated can INSERT (users trigger events without full auth).
- Only authenticated (admin) can SELECT — for report generation.
- No UPDATE or DELETE — events are append-only.

## Indexes
- (pharmacy_id, created_at) — per-pharmacy timeline queries
- (event_type, created_at) — per-type aggregation
- (governorate, created_at) — geographic reports
*/

CREATE TABLE IF NOT EXISTS pharmacy_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN ('search_appearance', 'detail_view', 'call_click')),
  account_id text,
  search_query text,
  latitude double precision,
  longitude double precision,
  governorate text,
  city text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE pharmacy_events ENABLE ROW LEVEL SECURITY;

-- Allow anyone to insert events (users trigger them)
DROP POLICY IF EXISTS "anon_insert_pharmacy_events" ON pharmacy_events;
CREATE POLICY "anon_insert_pharmacy_events" ON pharmacy_events
  FOR INSERT TO anon, authenticated WITH CHECK (true);

-- Only authenticated (admin) can read events for reports
DROP POLICY IF EXISTS "authenticated_read_pharmacy_events" ON pharmacy_events;
CREATE POLICY "authenticated_read_pharmacy_events" ON pharmacy_events
  FOR SELECT TO authenticated USING (true);

-- Indexes for report queries
CREATE INDEX IF NOT EXISTS idx_pharmacy_events_pharmacy_created
  ON pharmacy_events (pharmacy_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pharmacy_events_type_created
  ON pharmacy_events (event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pharmacy_events_gov_created
  ON pharmacy_events (governorate, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pharmacy_events_created
  ON pharmacy_events (created_at DESC);
