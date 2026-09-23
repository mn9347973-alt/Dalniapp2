/*
# Add district column to search logs and pharmacy events

## Purpose
The user_medicine_search_logs and pharmacy_events tables currently store
`governorate` and `city`. With the new official Yemen governorates/districts
guide, the `city` column has been repurposed to store the district name
(المديرية). This migration adds an explicit `district` column so reports and
statistics can display the district clearly, and backfills it from `city` so
existing rows are preserved.

## Changes
1. `user_medicine_search_logs`: add `district text` (nullable).
2. `pharmacy_events`: add `district text` (nullable).
3. Backfill `district` from `city` for existing rows (no data loss).
4. Add indexes on `district` for both tables to support geographic reports.

## Security
- No RLS policy changes. Existing policies remain in effect.
- No data is deleted or transformed destructively.
*/

ALTER TABLE user_medicine_search_logs
  ADD COLUMN IF NOT EXISTS district text;

ALTER TABLE pharmacy_events
  ADD COLUMN IF NOT EXISTS district text;

UPDATE user_medicine_search_logs
SET district = city
WHERE district IS NULL AND city IS NOT NULL;

UPDATE pharmacy_events
SET district = city
WHERE district IS NULL AND city IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_medicine_search_logs_district
  ON user_medicine_search_logs (district);

CREATE INDEX IF NOT EXISTS idx_pharmacy_events_district
  ON pharmacy_events (district);
