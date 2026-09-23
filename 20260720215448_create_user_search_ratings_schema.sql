/*
# Dulni User Search & Ratings Schema

## Overview
Adds the backend support for the user-facing Search screen and the pharmacy rating system.
The search screen lets a user find a medicine in nearby pharmacies; results are sorted by
geographic distance from the user's GPS location. Users can also rate a pharmacy after using it.

## Context
Dulni uses custom client-side auth (no Supabase Auth). All RLS policies use
`TO anon, authenticated` with `USING (true)` — single-tenant trust model consistent with
existing tables. The frontend filters/enforces context.

## Tables Created
1. **pharmacy_ratings** — user-submitted ratings for pharmacies
   - id, pharmacy_id (FK pharmacies), account_id (the rater), rating (1-5 stars),
     comment (optional), created_at
   - Unique (pharmacy_id, account_id) — one rating per pharmacy per user account.
   - On insert/update/delete, a trigger recalculates the pharmacy's `rating` (average) and
     `rating_count` on the `pharmacies` row.

## Functions
- **search_pharmacies_with_medicine(p_query text, p_lat double precision, p_lng double precision)**
  — returns pharmacies that have the queried medicine in stock, sorted by distance from the
  user's location. Excludes: pharmacies with status != 'active', pharmacies with expired
  subscription_status (unless subscriptions are disabled via app_settings), medicines that are
  not visible, and medicines whose (scientific_name, trade_name) pair exists in banned_medicines.
  The query matches scientific_name OR trade_name case-insensitively, including partial matches.
  Returns: pharmacy_id, name, address, governorate, city, phone, whatsapp, landline, open_time,
  close_time, is_24h, latitude, longitude, facade_image_path, rating, rating_count, about,
  medicine_id, scientific_name, trade_name, manufacturer, distance_meters.
- **autocomplete_medicines(p_query text)** — returns up to 10 distinct (scientific_name,
  trade_name) pairs from approved_medicines (not paused, not banned) matching the query, for
  the autocomplete dropdown. Only returns drugs that exist in at least one pharmacy's visible
  inventory.
- **submit_pharmacy_rating(p_pharmacy_id uuid, p_account_id text, p_rating int, p_comment text)**
  — upserts a rating (one per user per pharmacy) and returns the new average rating.

## Security (RLS)
- pharmacy_ratings: RLS enabled, `TO anon, authenticated` CRUD.

## Notes
1. Idempotent: IF NOT EXISTS for tables/indexes; DROP IF EXISTS before CREATE POLICY/FUNCTION/TRIGGER.
2. The search function reads app_settings.subscriptions_enabled to decide whether to filter
   out pharmacies with expired/no subscriptions.
3. Distance is calculated with the Haversine formula (meters).
4. Only medicines with is_visible=true and status='available' are returned.
5. Banned medicines are excluded by checking banned_medicines (case-insensitive name match).
*/

-- ============ pharmacy_ratings ============
CREATE TABLE IF NOT EXISTS pharmacy_ratings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  account_id text NOT NULL,
  rating integer NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS pharmacy_ratings_pharmacy_account_key
  ON pharmacy_ratings(pharmacy_id, account_id);
CREATE INDEX IF NOT EXISTS pharmacy_ratings_pharmacy_idx ON pharmacy_ratings(pharmacy_id);

ALTER TABLE pharmacy_ratings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ratings_select_all" ON pharmacy_ratings;
CREATE POLICY "ratings_select_all" ON pharmacy_ratings FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "ratings_insert_all" ON pharmacy_ratings;
CREATE POLICY "ratings_insert_all" ON pharmacy_ratings FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "ratings_update_all" ON pharmacy_ratings;
CREATE POLICY "ratings_update_all" ON pharmacy_ratings FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "ratings_delete_all" ON pharmacy_ratings;
CREATE POLICY "ratings_delete_all" ON pharmacy_ratings FOR DELETE
  TO anon, authenticated USING (true);

-- ============ trigger: recalc pharmacy rating on rating change ============
CREATE OR REPLACE FUNCTION recalc_pharmacy_rating()
RETURNS trigger AS $$
DECLARE
  p_id uuid;
BEGIN
  p_id := COALESCE(NEW.pharmacy_id, OLD.pharmacy_id);
  IF p_id IS NOT NULL THEN
    UPDATE pharmacies p SET
      rating = COALESCE((SELECT ROUND(AVG(rating), 2) FROM pharmacy_ratings WHERE pharmacy_id = p_id), 0),
      rating_count = (SELECT COUNT(*) FROM pharmacy_ratings WHERE pharmacy_id = p_id),
      updated_at = now()
    WHERE p.id = p_id;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS pharmacy_ratings_recalc ON pharmacy_ratings;
CREATE TRIGGER pharmacy_ratings_recalc
  AFTER INSERT OR UPDATE OR DELETE ON pharmacy_ratings
  FOR EACH ROW EXECUTE FUNCTION recalc_pharmacy_rating();

-- ============ search function ============
CREATE OR REPLACE FUNCTION search_pharmacies_with_medicine(
  p_query text,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL
)
RETURNS TABLE (
  pharmacy_id uuid,
  name text,
  address text,
  governorate text,
  city text,
  phone text,
  whatsapp text,
  landline text,
  open_time time,
  close_time time,
  is_24h boolean,
  latitude double precision,
  longitude double precision,
  facade_image_path text,
  rating numeric,
  rating_count integer,
  about text,
  medicine_id uuid,
  scientific_name text,
  trade_name text,
  manufacturer text,
  distance_meters double precision
) AS $$
DECLARE
  subs_enabled boolean;
  q text := lower(trim(p_query));
BEGIN
  IF q = '' THEN
    RETURN;
  END IF;

  SELECT COALESCE((value #>> '{}')::boolean, true) INTO subs_enabled
    FROM app_settings WHERE key = 'subscriptions_enabled';
  IF subs_enabled IS NULL THEN subs_enabled := true; END IF;

  RETURN QUERY
  SELECT
    ph.id AS pharmacy_id,
    ph.name,
    ph.address,
    ph.governorate,
    ph.city,
    ph.phone,
    ph.whatsapp,
    ph.landline,
    ph.open_time,
    ph.close_time,
    ph.is_24h,
    ph.latitude,
    ph.longitude,
    ph.facade_image_path,
    ph.rating,
    ph.rating_count,
    ph.about,
    m.id AS medicine_id,
    m.scientific_name,
    m.trade_name,
    m.manufacturer,
    CASE
      WHEN p_lat IS NOT NULL AND p_lng IS NOT NULL AND ph.latitude IS NOT NULL AND ph.longitude IS NOT NULL
      THEN 6371000 * 2 * asin(sqrt(
        power(sin(radians(ph.latitude - p_lat) / 2), 2) +
        cos(radians(p_lat)) * cos(radians(ph.latitude)) *
        power(sin(radians(ph.longitude - p_lng) / 2), 2)
      ))
      ELSE NULL
    END AS distance_meters
  FROM medicines m
  JOIN pharmacies ph ON ph.id = m.pharmacy_id
  WHERE
    m.is_visible = true
    AND m.status = 'available'
    AND ph.status = 'active'
    AND (lower(m.scientific_name) LIKE '%' || q || '%' OR lower(m.trade_name) LIKE '%' || q || '%')
    -- exclude banned medicines
    AND NOT EXISTS (
      SELECT 1 FROM banned_medicines b
      WHERE lower(b.scientific_name) = lower(m.scientific_name)
        AND lower(b.trade_name) = lower(m.trade_name)
    )
    -- exclude paused approved medicines
    AND NOT EXISTS (
      SELECT 1 FROM approved_medicines a
      WHERE lower(a.scientific_name) = lower(m.scientific_name)
        AND lower(a.trade_name) = lower(m.trade_name)
        AND a.is_paused = true
    )
    -- if subscriptions enabled, only show pharmacies with active subscription
    AND (
      NOT subs_enabled
      OR ph.subscription_status = 'active'
    )
  ORDER BY
    CASE WHEN distance_meters IS NOT NULL THEN distance_meters ELSE 999999999 END ASC,
    ph.rating DESC;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============ autocomplete function ============
CREATE OR REPLACE FUNCTION autocomplete_medicines(p_query text)
RETURNS TABLE (
  scientific_name text,
  trade_name text
) AS $$
DECLARE
  q text := lower(trim(p_query));
BEGIN
  IF length(q) < 3 THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT DISTINCT
    a.scientific_name,
    a.trade_name
  FROM approved_medicines a
  WHERE
    a.is_paused = false
    AND NOT EXISTS (
      SELECT 1 FROM banned_medicines b
      WHERE lower(b.scientific_name) = lower(a.scientific_name)
        AND lower(b.trade_name) = lower(a.trade_name)
    )
    AND (lower(a.scientific_name) LIKE '%' || q || '%' OR lower(a.trade_name) LIKE '%' || q || '%')
    AND EXISTS (
      SELECT 1 FROM medicines m
      JOIN pharmacies ph ON ph.id = m.pharmacy_id
      WHERE m.is_visible = true
        AND m.status = 'available'
        AND ph.status = 'active'
        AND lower(m.scientific_name) = lower(a.scientific_name)
        AND lower(m.trade_name) = lower(a.trade_name)
    )
  LIMIT 10;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============ submit rating function ============
CREATE OR REPLACE FUNCTION submit_pharmacy_rating(
  p_pharmacy_id uuid,
  p_account_id text,
  p_rating integer,
  p_comment text DEFAULT NULL
)
RETURNS numeric AS $$
DECLARE
  avg_rating numeric;
BEGIN
  IF p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Rating must be between 1 and 5';
  END IF;

  INSERT INTO pharmacy_ratings (pharmacy_id, account_id, rating, comment)
  VALUES (p_pharmacy_id, p_account_id, p_rating, p_comment)
  ON CONFLICT (pharmacy_id, account_id) DO UPDATE
    SET rating = EXCLUDED.rating, comment = EXCLUDED.comment;

  SELECT rating INTO avg_rating FROM pharmacies WHERE id = p_pharmacy_id;
  RETURN avg_rating;
END;
$$ LANGUAGE plpgsql;