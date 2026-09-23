-- =============================================================
-- 1) Reverse geocode function: nearest governorate + city from coordinates
-- =============================================================
CREATE OR REPLACE FUNCTION reverse_geocode(p_lat double precision, p_lng double precision)
RETURNS TABLE(governorate text, city text)
LANGUAGE sql
STABLE
AS $$
  WITH city_coords AS (
    SELECT * FROM (VALUES
      ('أمانة العاصمة', 'صنعاء', 15.3694, 44.1910),
      ('أمانة العاصمة', 'شعوب', 15.3850, 44.1900),
      ('أمانة العاصمة', 'الصافية', 15.3500, 44.2000),
      ('أمانة العاصمة', 'السبعين', 15.3500, 44.2100),
      ('أمانة العاصمة', 'الوحدة', 15.3600, 44.2000),
      ('أمانة العاصمة', 'معين', 15.3500, 44.2200),
      ('أمانة العاصمة', 'دار سلام', 15.3400, 44.1800),
      ('أمانة العاصمة', 'الحدان', 15.3700, 44.1600),
      ('أمانة العاصمة', 'بني الحارث', 15.4000, 44.2000),
      ('أمانة العاصمة', 'الزهرة', 15.3900, 44.1700),
      ('محافظة صنعاء', 'صنعاء', 15.3548, 44.2066),
      ('محافظة صنعاء', 'بني مطر', 15.2000, 44.0000),
      ('محافظة صنعاء', 'همدان', 15.5000, 44.1000),
      ('محافظة صنعاء', 'أرحب', 15.6000, 44.3000),
      ('محافظة صنعاء', 'خولان', 15.3000, 44.4000),
      ('محافظة صنعاء', 'نهم', 15.4000, 44.5000),
      ('محافظة صنعاء', 'مناخة', 15.0500, 43.7000),
      ('محافظة عدن', 'عدن', 12.7833, 45.0367),
      ('محافظة عدن', 'المعلا', 12.7800, 45.0000),
      ('محافظة عدن', 'التواهي', 12.7800, 45.0500),
      ('محافظة عدن', 'خور مكسر', 12.8000, 45.0300),
      ('محافظة عدن', 'الشيخ عثمان', 12.7900, 45.0600),
      ('محافظة عدن', 'المنصورة', 12.7900, 45.0400),
      ('محافظة عدن', 'البريقة', 12.7000, 44.9500),
      ('محافظة تعز', 'تعز', 13.5783, 44.0209),
      ('محافظة تعز', 'الحوبان', 13.6000, 44.0300),
      ('محافظة تعز', 'القاهرة', 13.5500, 44.0000),
      ('محافظة الحديدة', 'الحديدة', 14.7972, 42.9544),
      ('محافظة الحديدة', 'باجل', 14.7000, 43.1000),
      ('محافظة الحديدة', 'الزيدية', 14.9000, 42.9000),
      ('محافظة إب', 'إب', 13.9667, 44.1833),
      ('محافظة إب', 'يريم', 14.0000, 44.3000),
      ('محافظة إب', 'العدين', 13.9000, 44.1000),
      ('محافظة حضرموت', 'المكلا', 14.5333, 48.5167),
      ('محافظة حضرموت', 'الشحر', 14.5000, 48.6000),
      ('محافظة حضرموت', 'سيئون', 15.9000, 48.4000),
      ('محافظة ذمار', 'ذمار', 14.4167, 43.7500),
      ('محافظة ذمار', 'عتمة', 14.3000, 43.8000),
      ('محافظة حجة', 'حجة', 15.7000, 43.6000),
      ('محافظة صعدة', 'صعدة', 16.9167, 43.7500),
      ('محافظة عمران', 'عمران', 15.7000, 43.9500),
      ('محافظة عمران', 'خمر', 15.8000, 43.9000),
      ('محافظة المحويت', 'المحويت', 15.4500, 43.5000),
      ('محافظة لحج', 'الحوطة', 13.0500, 44.8000),
      ('محافظة أبين', 'زنجبار', 13.5000, 45.8333),
      ('محافظة شبوة', 'عتق', 14.4500, 46.8000),
      ('محافظة مأرب', 'مأرب', 15.4625, 45.3167),
      ('محافظة الجوف', 'الحزم', 16.0833, 44.5000),
      ('محافظة المهرة', 'الغيضة', 16.5000, 51.9000),
      ('محافظة الضالع', 'الضالع', 13.7000, 44.7333),
      ('محافظة البيضاء', 'البيضاء', 14.2833, 45.0167),
      ('محافظة ريمة', 'الجبين', 14.6500, 43.5000)
    ) AS t(governorate, city, lat, lng)
  ),
  ranked AS (
    SELECT
      t.governorate,
      t.city,
      (6371 * 2 * atan2(
        sqrt(
          sin(radians(t.lat - p_lat) / 2) ^ 2 +
          cos(radians(p_lat)) * cos(radians(t.lat)) * sin(radians(t.lng - p_lng) / 2) ^ 2
        ),
        sqrt(1 - (
          sin(radians(t.lat - p_lat) / 2) ^ 2 +
          cos(radians(p_lat)) * cos(radians(t.lat)) * sin(radians(t.lng - p_lng) / 2) ^ 2
        ))
      )) AS distance_km
    FROM city_coords t
  )
  SELECT governorate, city
  FROM ranked
  ORDER BY distance_km ASC
  LIMIT 1;
$$;

-- =============================================================
-- 2) Auto-populate app_users governorate/city from coordinates
-- =============================================================
CREATE OR REPLACE FUNCTION update_user_geo_from_coords(p_account_id text, p_lat double precision, p_lng double precision)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  geo RECORD;
BEGIN
  SELECT * INTO geo FROM reverse_geocode(p_lat, p_lng);
  IF geo.governorate IS NOT NULL THEN
    UPDATE app_users
    SET governorate = geo.governorate, city = geo.city
    WHERE account_id = p_account_id
      AND (governorate IS NULL OR city IS NULL);
  END IF;
END;
$$;

-- =============================================================
-- 3) Haversine distance function for precise pharmacy-user distance
-- =============================================================
CREATE OR REPLACE FUNCTION haversine_meters(p_lat1 double precision, p_lng1 double precision, p_lat2 double precision, p_lng2 double precision)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    6371000 * 2 * atan2(
      sqrt(
        sin(radians(p_lat2 - p_lat1) / 2) ^ 2 +
        cos(radians(p_lat1)) * cos(radians(p_lat2)) * sin(radians(p_lng2 - p_lng1) / 2) ^ 2
      ),
      sqrt(1 - (
        sin(radians(p_lat2 - p_lat1) / 2) ^ 2 +
        cos(radians(p_lat1)) * cos(radians(p_lat2)) * sin(radians(p_lng2 - p_lng1) / 2) ^ 2
      ))
    );
$$;

-- =============================================================
-- 4) Performance indexes for 100k users / 10k pharmacies scale
-- =============================================================
CREATE INDEX IF NOT EXISTS idx_app_users_governorate_city ON app_users (governorate, city);
CREATE INDEX IF NOT EXISTS idx_search_logs_gov_city_date ON user_medicine_search_logs (governorate, city, searched_at DESC);
CREATE INDEX IF NOT EXISTS idx_pharmacy_events_type_created ON pharmacy_events (event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pharmacy_events_gov_city ON pharmacy_events (governorate, city);
CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_read ON chat_messages (sender, read_at);
CREATE INDEX IF NOT EXISTS idx_broadcast_messages_created ON broadcast_messages (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_system_user_messages_active ON system_user_messages (is_active, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_medicines_manufacturer ON medicines (manufacturer);
CREATE INDEX IF NOT EXISTS idx_pharmacies_gov_city_status ON pharmacies (governorate, city, status);
CREATE INDEX IF NOT EXISTS idx_pharmacy_audit_logs_created ON pharmacy_audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_archives_pharmacy ON chat_archives (pharmacy_id);
