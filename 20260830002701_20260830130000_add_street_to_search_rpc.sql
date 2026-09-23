-- Add street column to search RPC functions return columns
-- so PharmacyDetails can display governorate, district, and address separately.

DROP FUNCTION IF EXISTS public.search_pharmacies_with_medicine(text, double precision, double precision);
DROP FUNCTION IF EXISTS public.search_pharmacies_with_medicine_paginated(text, double precision, double precision, integer, integer);

CREATE OR REPLACE FUNCTION public.search_pharmacies_with_medicine(
  p_query text,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL
)
RETURNS TABLE(
  pharmacy_id uuid,
  name text,
  address text,
  governorate text,
  city text,
  street text,
  phone text,
  whatsapp text,
  landline text,
  open_time time without time zone,
  close_time time without time zone,
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
  description text,
  country text,
  agent text,
  trade_name_en text,
  scientific_name_en text,
  distance_meters double precision
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  subs_enabled boolean;
  q text := lower(trim(p_query));
BEGIN
  IF q = '' THEN RETURN; END IF;

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
    ph.street,
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
    m.description,
    m.country,
    m.agent,
    m.trade_name_en,
    m.scientific_name_en,
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
      lower(COALESCE(m.scientific_name, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.trade_name, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.scientific_name_en, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.trade_name_en, '')) LIKE '%' || q || '%'
    )
    AND NOT EXISTS (
      SELECT 1 FROM banned_medicines b
      WHERE (
        (m.trade_name IS NOT NULL AND lower(b.trade_name) = lower(m.trade_name))
        OR (m.trade_name_en IS NOT NULL AND lower(b.trade_name_en) = lower(m.trade_name_en))
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM approved_medicines a
      WHERE (
        (m.trade_name IS NOT NULL AND lower(a.trade_name) = lower(m.trade_name))
        OR (m.trade_name_en IS NOT NULL AND lower(a.trade_name_en) = lower(m.trade_name_en))
      )
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
$function$;

CREATE OR REPLACE FUNCTION public.search_pharmacies_with_medicine_paginated(
  p_query text,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_limit integer DEFAULT 7,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(
  pharmacy_id uuid,
  name text,
  address text,
  governorate text,
  city text,
  street text,
  phone text,
  whatsapp text,
  landline text,
  open_time time without time zone,
  close_time time without time zone,
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
  description text,
  country text,
  agent text,
  trade_name_en text,
  scientific_name_en text,
  distance_meters double precision,
  total_count integer
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  subs_enabled boolean;
  q text := lower(trim(p_query));
  v_total integer;
BEGIN
  IF q = '' THEN RETURN; END IF;

  SELECT COALESCE((value #>> '{}')::boolean, true) INTO subs_enabled
  FROM app_settings WHERE key = 'subscriptions_enabled';
  IF subs_enabled IS NULL THEN subs_enabled := true; END IF;

  SELECT count(*) INTO v_total
  FROM medicines m
  JOIN pharmacies ph ON ph.id = m.pharmacy_id
  WHERE
    m.is_visible = true
    AND m.status = 'available'
    AND ph.status = 'active'
    AND (
      lower(COALESCE(m.scientific_name, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.trade_name, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.scientific_name_en, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.trade_name_en, '')) LIKE '%' || q || '%'
    )
    AND NOT EXISTS (
      SELECT 1 FROM banned_medicines b
      WHERE (
        (m.trade_name IS NOT NULL AND lower(b.trade_name) = lower(m.trade_name))
        OR (m.trade_name_en IS NOT NULL AND lower(b.trade_name_en) = lower(m.trade_name_en))
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM approved_medicines a
      WHERE (
        (m.trade_name IS NOT NULL AND lower(a.trade_name) = lower(m.trade_name))
        OR (m.trade_name_en IS NOT NULL AND lower(a.trade_name_en) = lower(m.trade_name_en))
      )
      AND a.is_paused = true
    )
    AND (
      NOT subs_enabled
      OR ph.subscription_status = 'active'
    );

  RETURN QUERY
  SELECT
    ph.id AS pharmacy_id,
    ph.name,
    ph.address,
    ph.governorate,
    ph.city,
    ph.street,
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
    m.description,
    m.country,
    m.agent,
    m.trade_name_en,
    m.scientific_name_en,
    CASE
      WHEN p_lat IS NOT NULL AND p_lng IS NOT NULL AND ph.latitude IS NOT NULL AND ph.longitude IS NOT NULL
      THEN 6371000 * 2 * asin(sqrt(
        power(sin(radians(ph.latitude - p_lat) / 2), 2) +
        cos(radians(p_lat)) * cos(radians(ph.latitude)) *
        power(sin(radians(ph.longitude - p_lng) / 2), 2)
      ))
      ELSE NULL
    END AS distance_meters,
    v_total AS total_count
  FROM medicines m
  JOIN pharmacies ph ON ph.id = m.pharmacy_id
  WHERE
    m.is_visible = true
    AND m.status = 'available'
    AND ph.status = 'active'
    AND (
      lower(COALESCE(m.scientific_name, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.trade_name, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.scientific_name_en, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(m.trade_name_en, '')) LIKE '%' || q || '%'
    )
    AND NOT EXISTS (
      SELECT 1 FROM banned_medicines b
      WHERE (
        (m.trade_name IS NOT NULL AND lower(b.trade_name) = lower(m.trade_name))
        OR (m.trade_name_en IS NOT NULL AND lower(b.trade_name_en) = lower(m.trade_name_en))
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM approved_medicines a
      WHERE (
        (m.trade_name IS NOT NULL AND lower(a.trade_name) = lower(m.trade_name))
        OR (m.trade_name_en IS NOT NULL AND lower(a.trade_name_en) = lower(m.trade_name_en))
      )
      AND a.is_paused = true
    )
    AND (
      NOT subs_enabled
      OR ph.subscription_status = 'active'
    )
  ORDER BY
    CASE WHEN distance_meters IS NOT NULL THEN distance_meters ELSE 999999999 END ASC,
    ph.rating DESC
  LIMIT p_limit OFFSET p_offset;
END;
$function$;
