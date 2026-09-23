-- Unify medicine data model: at least one trade name required, scientific name optional
-- Remove NOT NULL from scientific_name and trade_name; add CHECK constraint for at least one trade name
-- Update unique index, trigger, and RPC functions for null-safe matching

-- ============ 1. Make scientific_name and trade_name nullable ============
ALTER TABLE medicines ALTER COLUMN scientific_name DROP NOT NULL;
ALTER TABLE medicines ALTER COLUMN trade_name DROP NOT NULL;
ALTER TABLE approved_medicines ALTER COLUMN scientific_name DROP NOT NULL;
ALTER TABLE approved_medicines ALTER COLUMN trade_name DROP NOT NULL;
ALTER TABLE banned_medicines ALTER COLUMN scientific_name DROP NOT NULL;
ALTER TABLE banned_medicines ALTER COLUMN trade_name DROP NOT NULL;

-- ============ 2. Add CHECK constraints: at least one trade name ============
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'medicines_at_least_one_trade_name') THEN
    ALTER TABLE medicines ADD CONSTRAINT medicines_at_least_one_trade_name
      CHECK (trade_name IS NOT NULL OR trade_name_en IS NOT NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'approved_medicines_at_least_one_trade_name') THEN
    ALTER TABLE approved_medicines ADD CONSTRAINT approved_medicines_at_least_one_trade_name
      CHECK (trade_name IS NOT NULL OR trade_name_en IS NOT NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'banned_medicines_at_least_one_trade_name') THEN
    ALTER TABLE banned_medicines ADD CONSTRAINT banned_medicines_at_least_one_trade_name
      CHECK (trade_name IS NOT NULL OR trade_name_en IS NOT NULL);
  END IF;
END $$;

-- ============ 3. Replace unique index on medicines ============
DROP INDEX IF EXISTS medicines_pharmacy_trade_sci_key;
CREATE UNIQUE INDEX medicines_pharmacy_key
  ON medicines USING btree (
    pharmacy_id,
    COALESCE(lower(trade_name), ''),
    COALESCE(lower(trade_name_en), ''),
    COALESCE(lower(scientific_name), ''),
    COALESCE(lower(scientific_name_en), '')
  );

-- ============ 4. Update banned-check trigger function ============
CREATE OR REPLACE FUNCTION medicines_before_insert_check_banned_fn()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  banned_count integer;
  approved_count integer;
  pharmacy_owner text;
BEGIN
  -- Check if medicine is banned (match on either trade name)
  SELECT count(*) INTO banned_count
  FROM banned_medicines
  WHERE (
    (NEW.trade_name IS NOT NULL AND lower(banned_medicines.trade_name) = lower(NEW.trade_name))
    OR
    (NEW.trade_name_en IS NOT NULL AND lower(banned_medicines.trade_name_en) = lower(NEW.trade_name_en))
  );

  IF banned_count > 0 THEN
    RAISE EXCEPTION 'BANNED_MEDICINE: هذا الدواء محظور ولا يمكن إضافته';
  END IF;

  -- Check if already in approved catalog (match on either trade name)
  SELECT count(*) INTO approved_count
  FROM approved_medicines
  WHERE (
    (NEW.trade_name IS NOT NULL AND lower(approved_medicines.trade_name) = lower(NEW.trade_name))
    OR
    (NEW.trade_name_en IS NOT NULL AND lower(approved_medicines.trade_name_en) = lower(NEW.trade_name_en))
  );

  -- If not in approved catalog, auto-create entry
  IF approved_count = 0 THEN
    SELECT owner_account_id INTO pharmacy_owner
    FROM pharmacies WHERE id = NEW.pharmacy_id;

    INSERT INTO approved_medicines (
      scientific_name, trade_name, active_ingredient, manufacturer, type, concentration,
      dosage, category, description, country, agent,
      trade_name_en, scientific_name_en, manufacturer_en,
      is_paused, first_pharmacy_account, created_by
    ) VALUES (
      NEW.scientific_name, NEW.trade_name, NEW.active_ingredient, NEW.manufacturer, NEW.type, NEW.concentration,
      NEW.dosage, NEW.category, NEW.description, NEW.country, NEW.agent,
      NEW.trade_name_en, NEW.scientific_name_en, NEW.manufacturer_en,
      false, pharmacy_owner, pharmacy_owner
    );

    -- Log audit
    INSERT INTO medicine_audit_logs (action, list, scientific_name, trade_name, actor, note)
    VALUES ('add_approved', 'approved', NEW.scientific_name, NEW.trade_name, pharmacy_owner, 'إضافة تلقائية من صيدلية');
  END IF;

  RETURN NEW;
END;
$$;

-- ============ 5. Update check_medicine_banned function ============
CREATE OR REPLACE FUNCTION check_medicine_banned(p_scientific text, p_trade text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  found boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM banned_medicines
    WHERE (
      (p_trade IS NOT NULL AND lower(banned_medicines.trade_name) = lower(p_trade))
      OR
      (p_trade IS NOT NULL AND lower(banned_medicines.trade_name_en) = lower(p_trade))
    )
  ) INTO found;
  RETURN found;
END;
$$;

-- ============ 6. Update move_to_banned function ============
CREATE OR REPLACE FUNCTION move_to_banned(p_medicine_id uuid, p_actor text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  new_id uuid;
BEGIN
  SELECT * INTO r FROM approved_medicines WHERE id = p_medicine_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Approved medicine not found'; END IF;

  INSERT INTO banned_medicines (
    scientific_name, trade_name, active_ingredient, manufacturer, type, concentration,
    dosage, category, description, country, agent,
    trade_name_en, scientific_name_en, manufacturer_en,
    ban_reason, created_by
  ) VALUES (
    r.scientific_name, r.trade_name, r.active_ingredient, r.manufacturer, r.type, r.concentration,
    r.dosage, r.category, r.description, r.country, r.agent,
    r.trade_name_en, r.scientific_name_en, r.manufacturer_en,
    p_reason, p_actor
  )
  RETURNING id INTO new_id;

  DELETE FROM approved_medicines WHERE id = p_medicine_id;

  -- Remove from every pharmacy's inventory (null-safe match on trade names)
  DELETE FROM medicines WHERE
    (r.trade_name IS NOT NULL AND lower(medicines.trade_name) = lower(r.trade_name))
    OR
    (r.trade_name_en IS NOT NULL AND lower(medicines.trade_name_en) = lower(r.trade_name_en));

  INSERT INTO medicine_audit_logs (action, list, medicine_id, scientific_name, trade_name, actor, note)
  VALUES ('ban', 'banned', new_id, r.scientific_name, r.trade_name, p_actor, p_reason);

  RETURN new_id;
END;
$$;

-- ============ 7. Update move_to_approved function ============
CREATE OR REPLACE FUNCTION move_to_approved(p_banned_id uuid, p_actor text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  new_id uuid;
BEGIN
  SELECT * INTO r FROM banned_medicines WHERE id = p_banned_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Banned medicine not found'; END IF;

  INSERT INTO approved_medicines (
    scientific_name, trade_name, active_ingredient, manufacturer, type, concentration,
    dosage, category, description, country, agent,
    trade_name_en, scientific_name_en, manufacturer_en,
    is_paused, first_pharmacy_account, created_by
  ) VALUES (
    r.scientific_name, r.trade_name, r.active_ingredient, r.manufacturer, r.type, r.concentration,
    r.dosage, r.category, r.description, r.country, r.agent,
    r.trade_name_en, r.scientific_name_en, r.manufacturer_en,
    false, null, p_actor
  )
  RETURNING id INTO new_id;

  DELETE FROM banned_medicines WHERE id = p_banned_id;

  INSERT INTO medicine_audit_logs (action, list, medicine_id, scientific_name, trade_name, actor, note)
  VALUES ('approve', 'approved', new_id, r.scientific_name, r.trade_name, p_actor, 'اعتماد دواء من القائمة المحظورة');

  RETURN new_id;
END;
$$;

-- ============ 8. Update search_pharmacies_with_medicine function ============
CREATE OR REPLACE FUNCTION search_pharmacies_with_medicine(
  p_query text, p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL
)
RETURNS TABLE(
  pharmacy_id uuid, name text, address text, governorate text, city text,
  phone text, whatsapp text, landline text, open_time time without time zone,
  close_time time without time zone, is_24h boolean, latitude double precision,
  longitude double precision, facade_image_path text, rating numeric, rating_count integer,
  about text, medicine_id uuid, scientific_name text, trade_name text, manufacturer text,
  dosage text, category text, description text, country text, agent text,
  trade_name_en text, scientific_name_en text, manufacturer_en text, distance_meters double precision
)
LANGUAGE plpgsql
STABLE
AS $$
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
$$;

-- ============ 9. Update autocomplete_medicines function ============
CREATE OR REPLACE FUNCTION autocomplete_medicines(p_query text)
RETURNS TABLE(scientific_name text, trade_name text, trade_name_en text, scientific_name_en text)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  q text := lower(trim(p_query));
BEGIN
  IF length(q) < 3 THEN RETURN; END IF;

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
      WHERE (
        (a.trade_name IS NOT NULL AND lower(b.trade_name) = lower(a.trade_name))
        OR (a.trade_name_en IS NOT NULL AND lower(b.trade_name_en) = lower(a.trade_name_en))
      )
    )
    AND (
      lower(COALESCE(a.scientific_name, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(a.trade_name, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(a.scientific_name_en, '')) LIKE '%' || q || '%'
      OR lower(COALESCE(a.trade_name_en, '')) LIKE '%' || q || '%'
    )
    AND EXISTS (
      SELECT 1 FROM medicines m
      JOIN pharmacies ph ON ph.id = m.pharmacy_id
      WHERE m.is_visible = true
      AND m.status = 'available'
      AND ph.status = 'active'
      AND (
        (a.trade_name IS NOT NULL AND lower(m.trade_name) = lower(a.trade_name))
        OR (a.trade_name_en IS NOT NULL AND lower(m.trade_name_en) = lower(a.trade_name_en))
      )
    )
    LIMIT 10;
END;
$$;
