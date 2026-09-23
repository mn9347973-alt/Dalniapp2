-- =============================================================
-- 1) Pharmacy approval: admin-selected plan override
-- =============================================================
ALTER TABLE pharmacy_applications
  ADD COLUMN IF NOT EXISTS admin_selected_plan_id uuid;

CREATE OR REPLACE FUNCTION approve_pharmacy_application(
  app_id uuid,
  reviewer_account text,
  admin_plan_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  app RECORD;
  new_pharmacy_id uuid;
  dur int;
  final_plan_id uuid;
BEGIN
  SELECT * INTO app FROM pharmacy_applications WHERE id = app_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application not found';
  END IF;
  IF app.status = 'approved' THEN
    RAISE EXCEPTION 'Application already approved';
  END IF;

  final_plan_id := COALESCE(admin_plan_id, app.admin_selected_plan_id, app.plan_id);

  UPDATE pharmacy_applications
  SET admin_selected_plan_id = final_plan_id
  WHERE id = app_id;

  dur := COALESCE(NULLIF((SELECT duration_days FROM subscription_plans WHERE id = final_plan_id), 0), 30);

  INSERT INTO pharmacies (
    owner_account_id, application_id, name, address, latitude, longitude,
    phone, whatsapp, landline, open_time, close_time, is_24h,
    governorate, city, facade_image_path, license_image_path, id_card_image_path,
    status, subscription_plan_id, subscription_started_at, subscription_ends_at,
    subscription_status
  )
  VALUES (
    app.account_id, app.id, app.name, app.address, app.latitude, app.longitude,
    app.phone, app.whatsapp, app.landline, app.open_time, app.close_time, app.is_24h,
    app.governorate, app.city, app.facade_image_path, app.license_image_path, app.id_card_image_path,
    'active', final_plan_id, now(),
    CASE WHEN final_plan_id IS NOT NULL THEN now() + (dur * interval '1 day') ELSE NULL END,
    'active'
  )
  ON CONFLICT (owner_account_id) DO UPDATE SET
    name = EXCLUDED.name,
    address = EXCLUDED.address,
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    phone = EXCLUDED.phone,
    whatsapp = EXCLUDED.whatsapp,
    landline = EXCLUDED.landline,
    open_time = EXCLUDED.open_time,
    close_time = EXCLUDED.close_time,
    is_24h = EXCLUDED.is_24h,
    governorate = EXCLUDED.governorate,
    city = EXCLUDED.city,
    facade_image_path = EXCLUDED.facade_image_path,
    license_image_path = EXCLUDED.license_image_path,
    id_card_image_path = EXCLUDED.id_card_image_path,
    application_id = EXCLUDED.application_id,
    subscription_plan_id = EXCLUDED.subscription_plan_id,
    subscription_started_at = EXCLUDED.subscription_started_at,
    subscription_ends_at = EXCLUDED.subscription_ends_at,
    subscription_status = EXCLUDED.subscription_status,
    status = 'active',
    updated_at = now()
  RETURNING id INTO new_pharmacy_id;

  UPDATE pharmacy_applications
  SET status = 'approved', reviewed_by = reviewer_account, reviewed_at = now(), updated_at = now()
  WHERE id = app_id;

  INSERT INTO pharmacy_edit_logs (pharmacy_id, action, changed_by, note)
  VALUES (new_pharmacy_id, 'approved', reviewer_account, 'تم اعتماد الصيدلية من طلب التسجيل');

  RETURN new_pharmacy_id;
END;
$$;

-- =============================================================
-- 2) Broadcast messages (separate from pharmacy chat)
-- =============================================================
CREATE TABLE IF NOT EXISTS broadcast_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  body text NOT NULL,
  audience text NOT NULL DEFAULT 'all_pharmacies',
  sent_by text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE broadcast_messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "select_broadcast_messages" ON broadcast_messages FOR SELECT TO authenticated USING (true);
CREATE POLICY "insert_broadcast_messages" ON broadcast_messages FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "update_broadcast_messages" ON broadcast_messages FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "delete_broadcast_messages" ON broadcast_messages FOR DELETE TO authenticated USING (true);

-- =============================================================
-- 3) System user messages (admin-managed, shown to app users)
-- =============================================================
CREATE TABLE IF NOT EXISTS system_user_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  body text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE system_user_messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "select_system_user_messages" ON system_user_messages FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "insert_system_user_messages" ON system_user_messages FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "update_system_user_messages" ON system_user_messages FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "delete_system_user_messages" ON system_user_messages FOR DELETE TO authenticated USING (true);

-- =============================================================
-- 4) Maintenance mode + image size settings defaults
-- =============================================================
INSERT INTO app_settings (key, value)
VALUES
  ('maintenance_mode', 'false'::jsonb),
  ('search_image_height', '180'::jsonb),
  ('search_image_max_height', '240'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- =============================================================
-- 5) Geographic columns on app_users
-- =============================================================
ALTER TABLE app_users
  ADD COLUMN IF NOT EXISTS governorate text,
  ADD COLUMN IF NOT EXISTS city text;

-- =============================================================
-- 6) Performance indexes
-- =============================================================
CREATE INDEX IF NOT EXISTS idx_search_logs_searched_at ON user_medicine_search_logs (searched_at DESC);
CREATE INDEX IF NOT EXISTS idx_search_logs_governorate ON user_medicine_search_logs (governorate);
CREATE INDEX IF NOT EXISTS idx_search_logs_city ON user_medicine_search_logs (city);
CREATE INDEX IF NOT EXISTS idx_search_logs_account ON user_medicine_search_logs (account_id);
CREATE INDEX IF NOT EXISTS idx_pharmacy_events_pharmacy_type ON pharmacy_events (pharmacy_id, event_type);
CREATE INDEX IF NOT EXISTS idx_pharmacy_events_created_at ON pharmacy_events (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_medicines_pharmacy_status ON medicines (pharmacy_id, status);
CREATE INDEX IF NOT EXISTS idx_pharmacies_status ON pharmacies (status);
CREATE INDEX IF NOT EXISTS idx_pharmacies_subscription_status ON pharmacies (subscription_status);
CREATE INDEX IF NOT EXISTS idx_pharmacies_governorate ON pharmacies (governorate);
CREATE INDEX IF NOT EXISTS idx_pharmacies_city ON pharmacies (city);
CREATE INDEX IF NOT EXISTS idx_chat_messages_pharmacy_created ON chat_messages (pharmacy_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_subscription_renewals_status ON subscription_renewals (status);
CREATE INDEX IF NOT EXISTS idx_pharmacy_applications_status ON pharmacy_applications (status);
CREATE INDEX IF NOT EXISTS idx_app_users_account_id ON app_users (account_id);
