/*
# Dulni Medicine Data Enhancement (fix: drop functions before recreate)

Follow-up to enhance_medicine_data_model. The columns were already added successfully;
this migration drops and recreates the search/autocomplete functions with the new return
types (the previous attempt failed because CREATE OR REPLACE cannot change the OUT parameter
list of an existing function).
*/

-- Drop old versions (signatures must match exactly)
DROP FUNCTION IF EXISTS search_pharmacies_with_medicine(text, double precision, double precision);
DROP FUNCTION IF EXISTS autocomplete_medicines(text);

-- ============ Recreate search function with new columns ============
CREATE FUNCTION search_pharmacies_with_medicine(
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
  dosage text,
  category text,
  description text,
  country text,
  agent text,
  trade_name_en text,
  scientific_name_en text,
  manufacturer_en text,
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
    m.dosage,
    m.category,
    m.description,
    m.country,
    m.agent,
    m.trade_name_en,
    m.scientific_name_en,
    m.manufacturer_en,
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
    AND (
      lower(m.scientific_name) LIKE '%' || q || '%'
      OR lower(m.trade_name) LIKE '%' || q || '%'
      OR lower(COALESCE(m.scientific_name_en, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.trade_name_en, '')) LIKE '%' || q || '%'
    )
    AND NOT EXISTS (
      SELECT 1 FROM banned_medicines b
      WHERE lower(b.scientific_name) = lower(m.scientific_name)
        AND lower(b.trade_name) = lower(m.trade_name)
    )
    AND NOT EXISTS (
      SELECT 1 FROM approved_medicines a
      WHERE lower(a.scientific_name) = lower(m.scientific_name)
        AND lower(a.trade_name) = lower(m.trade_name)
        AND a.is_paused = true
    )
    AND (
      NOT subs_enabled
      OR ph.subscription_status = 'active'
    )
  ORDER BY
    CASE WHEN distance_meters IS NOT NULL THEN distance_meters ELSE 999999999 END ASC,
    ph.rating DESC;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============ Recreate autocomplete function with new columns ============
CREATE FUNCTION autocomplete_medicines(p_query text)
RETURNS TABLE (
  scientific_name text,
  trade_name text,
  trade_name_en text,
  scientific_name_en text
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
    a.trade_name,
    a.trade_name_en,
    a.scientific_name_en
  FROM approved_medicines a
  WHERE
    a.is_paused = false
    AND NOT EXISTS (
      SELECT 1 FROM banned_medicines b
      WHERE lower(b.scientific_name) = lower(a.scientific_name)
        AND lower(b.trade_name) = lower(a.trade_name)
    )
    AND (
      lower(a.scientific_name) LIKE '%' || q || '%'
      OR lower(a.trade_name) LIKE '%' || q || '%'
      OR lower(COALESCE(a.scientific_name_en, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(a.trade_name_en, '')) LIKE '%' || q || '%'
    )
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