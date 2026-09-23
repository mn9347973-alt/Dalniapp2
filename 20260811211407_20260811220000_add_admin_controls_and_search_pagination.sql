/*
# Add admin-controllable settings and search pagination support

## Changes:
1. New app_settings keys:
   - `chat_daily_limit` (integer, default 5): admin-configurable daily chat message limit per pharmacy
   - `stats_visible` (boolean, default true): show/hide the entire pharmacy stats section
   - `stats_config` (jsonb): per-stat visibility flags, each defaulting to true

2. Updated `send_pharmacy_message` RPC:
   - Reads `chat_daily_limit` from app_settings instead of hardcoded 5
   - Falls back to 5 if setting is missing/invalid

3. New `search_pharmacies_with_medicine_paginated` RPC:
   - Accepts `p_limit` and `p_offset` parameters for progressive loading
   - Returns total_count alongside results
   - Preserves existing ordering by distance then rating

4. All existing functionality preserved. No data loss.
*/

-- Insert new app_settings keys
INSERT INTO app_settings (key, value)
VALUES
  ('chat_daily_limit', to_jsonb(5)),
  ('stats_visible', to_jsonb(true)),
  ('stats_config', '{"ratingCount": true, "avgRating": true, "totalMeds": true, "available": true, "unavailable": true, "paused": true, "searchCount": true}'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- Update send_pharmacy_message to use configurable daily limit
CREATE OR REPLACE FUNCTION public.send_pharmacy_message(p_pharmacy_id uuid, p_body text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  msg_id uuid;
  today_count integer;
  daily_limit integer;
BEGIN
  IF trim(coalesce(p_body, '')) = '' THEN
    RAISE EXCEPTION 'Body cannot be empty';
  END IF;

  SELECT COALESCE((value #>> '{}')::integer, 5) INTO daily_limit
  FROM app_settings WHERE key = 'chat_daily_limit';
  IF daily_limit IS NULL OR daily_limit < 1 THEN
    daily_limit := 5;
  END IF;

  SELECT count INTO today_count
  FROM chat_daily_counters
  WHERE pharmacy_id = p_pharmacy_id AND day = current_date;

  IF today_count IS NULL THEN
    INSERT INTO chat_daily_counters (pharmacy_id, day, count)
    VALUES (p_pharmacy_id, current_date, 1);
  ELSIF today_count >= daily_limit THEN
    RAISE EXCEPTION 'Daily limit reached';
  ELSE
    UPDATE chat_daily_counters SET count = count + 1
    WHERE pharmacy_id = p_pharmacy_id AND day = current_date;
  END IF;

  INSERT INTO chat_messages (pharmacy_id, sender, body)
  VALUES (p_pharmacy_id, 'pharmacy', p_body)
  RETURNING id INTO msg_id;

  RETURN msg_id;
END;
$function$;

-- Create new paginated search function
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

  -- Get total count
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
