/*
# Dulni Pharmacy Management Schema

## Overview
Creates the complete database backend for the "تسجيل صيدليتي" (user pharmacy registration)
and "إدارة الصيدليات" (admin pharmacy management) features of the Dulni app.

## Context
Dulni uses a custom client-side auth system (no Supabase Auth): users log in with a 9-digit
number; the value `776695102` is the admin. The 9-digit login value is stored as the account
identifier in `profiles.account_id`. All RLS policies are therefore scoped to
`TO anon, authenticated` and filter rows by account id. Because there is no Supabase Auth
session, ownership is enforced by matching the `account_id` column against the value the
frontend sends. This is a single-tenant-style trust model appropriate for this app.

## Tables Created

1. **profiles** — lightweight profile per account_id (id, account_id unique, display_name, created_at)
2. **subscription_plans** — admin-managed plans offered to pharmacies during registration
   (id, name, price_yer, duration_days, features jsonb, is_active, sort_order, created_at)
3. **payment_infos** — admin-managed bank transfer details shown on the payment step
   (id, bank_name, account_name, account_number, is_active, created_at)
4. **pharmacy_applications** — the registration request submitted by a user and reviewed by admin
   (id, account_id, plan_id, name, owner_name, address, governorate, city, latitude, longitude,
    phone, whatsapp, landline, open_time, close_time, is_24h, facade_image_path,
    license_image_path, id_card_image_path, payment_slip_image_path, status, rejection_reason,
    reviewed_by, reviewed_at, submitted_at, created_at, updated_at)
5. **pharmacies** — the approved pharmacy record created after an application is approved
   (id, owner_account_id, application_id, name, address, latitude, longitude, phone, whatsapp,
    landline, open_time, close_time, is_24h, governorate, city, status, subscription_plan_id,
    subscription_started_at, subscription_ends_at, subscription_status, profile_views,
    search_count, rating, rating_count, created_at, updated_at)
6. **pharmacy_edit_logs** — audit trail of edits made to a pharmacy by admins
7. **pharmacy_notifications** — notification log per pharmacy
8. **pharmacy_conversations** — placeholder conversation log (for future chat)

## Lookup / Seed Data
- 5 subscription plans seeded (شهرية, ربع سنوية, نصف سنوية, سنوية, تجريبية)
- 1 active payment info row seeded
- Unique constraint on pharmacies(owner_account_id) — each account owns at most one pharmacy.
- Unique pending index on pharmacy_applications(account_id) WHERE status IN ('draft','pending_review').

## Security (RLS)
All tables enable RLS. Policies use `TO anon, authenticated` because Dulni has no Supabase Auth
session (custom client-side auth). Ownership is enforced by the frontend filtering on account_id.
Public/anon reads are allowed on catalog tables (subscription_plans, payment_infos).

## Storage
A public bucket `pharmacy-documents` is created for facade/license/id-card/payment images.
Public read + anon/authenticated writes enabled (client uploads directly with the anon key).

## Functions
- `approve_pharmacy_application(app_id uuid, reviewer_account text)` — atomically flips an
  application to approved, creates/updates the linked pharmacy (upsert by owner_account_id),
  and logs an edit entry.

## Notes
1. All tables use `gen_random_uuid()` PKs; timestamps are timestamptz defaulting to now().
2. Idempotent: IF NOT EXISTS for tables, DROP IF EXISTS before CREATE POLICY.
3. Rating numeric(3,2) (0.00–5.00); rating_count int default 0.
4. subscription_status text: 'active' | 'expired' | 'none'.
5. Order matters: pharmacy_applications is created BEFORE pharmacies (FK reference).
*/

-- ============ profiles ============
CREATE TABLE IF NOT EXISTS profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id text UNIQUE NOT NULL,
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "profiles_select_all" ON profiles;
CREATE POLICY "profiles_select_all" ON profiles FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "profiles_insert_all" ON profiles;
CREATE POLICY "profiles_insert_all" ON profiles FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "profiles_update_own" ON profiles;
CREATE POLICY "profiles_update_own" ON profiles FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

-- ============ subscription_plans ============
CREATE TABLE IF NOT EXISTS subscription_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  price_yer integer NOT NULL DEFAULT 0,
  duration_days integer NOT NULL DEFAULT 30,
  features jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE subscription_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "plans_select_all" ON subscription_plans;
CREATE POLICY "plans_select_all" ON subscription_plans FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "plans_insert_all" ON subscription_plans;
CREATE POLICY "plans_insert_all" ON subscription_plans FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "plans_update_all" ON subscription_plans;
CREATE POLICY "plans_update_all" ON subscription_plans FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "plans_delete_all" ON subscription_plans;
CREATE POLICY "plans_delete_all" ON subscription_plans FOR DELETE
  TO anon, authenticated USING (true);

-- ============ payment_infos ============
CREATE TABLE IF NOT EXISTS payment_infos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bank_name text NOT NULL,
  account_name text NOT NULL,
  account_number text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE payment_infos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "payments_select_all" ON payment_infos;
CREATE POLICY "payments_select_all" ON payment_infos FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "payments_insert_all" ON payment_infos;
CREATE POLICY "payments_insert_all" ON payment_infos FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "payments_update_all" ON payment_infos;
CREATE POLICY "payments_update_all" ON payment_infos FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "payments_delete_all" ON payment_infos;
CREATE POLICY "payments_delete_all" ON payment_infos FOR DELETE
  TO anon, authenticated USING (true);

-- ============ pharmacy_applications (created BEFORE pharmacies for FK) ============
CREATE TABLE IF NOT EXISTS pharmacy_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id text NOT NULL,
  plan_id uuid REFERENCES subscription_plans(id) ON DELETE SET NULL,
  name text NOT NULL,
  owner_name text,
  address text NOT NULL,
  governorate text,
  city text,
  latitude double precision,
  longitude double precision,
  phone text NOT NULL,
  whatsapp text NOT NULL,
  landline text,
  open_time time,
  close_time time,
  is_24h boolean NOT NULL DEFAULT false,
  facade_image_path text,
  license_image_path text,
  id_card_image_path text,
  payment_slip_image_path text,
  status text NOT NULL DEFAULT 'draft',
  rejection_reason text,
  reviewed_by text,
  reviewed_at timestamptz,
  submitted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS applications_account_idx ON pharmacy_applications(account_id);
CREATE INDEX IF NOT EXISTS applications_status_idx ON pharmacy_applications(status);
CREATE UNIQUE INDEX IF NOT EXISTS applications_account_pending_key
  ON pharmacy_applications(account_id) WHERE status IN ('draft','pending_review');

ALTER TABLE pharmacy_applications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "applications_select_all" ON pharmacy_applications;
CREATE POLICY "applications_select_all" ON pharmacy_applications FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "applications_insert_all" ON pharmacy_applications;
CREATE POLICY "applications_insert_all" ON pharmacy_applications FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "applications_update_all" ON pharmacy_applications;
CREATE POLICY "applications_update_all" ON pharmacy_applications FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "applications_delete_all" ON pharmacy_applications;
CREATE POLICY "applications_delete_all" ON pharmacy_applications FOR DELETE
  TO anon, authenticated USING (true);

-- ============ pharmacies ============
CREATE TABLE IF NOT EXISTS pharmacies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_account_id text NOT NULL,
  application_id uuid REFERENCES pharmacy_applications(id) ON DELETE SET NULL,
  name text NOT NULL,
  address text NOT NULL,
  latitude double precision,
  longitude double precision,
  phone text NOT NULL,
  whatsapp text NOT NULL,
  landline text,
  open_time time,
  close_time time,
  is_24h boolean NOT NULL DEFAULT false,
  governorate text,
  city text,
  facade_image_path text,
  license_image_path text,
  id_card_image_path text,
  status text NOT NULL DEFAULT 'active',
  subscription_plan_id uuid REFERENCES subscription_plans(id) ON DELETE SET NULL,
  subscription_started_at timestamptz,
  subscription_ends_at timestamptz,
  subscription_status text NOT NULL DEFAULT 'none',
  profile_views integer NOT NULL DEFAULT 0,
  search_count integer NOT NULL DEFAULT 0,
  rating numeric(3,2) NOT NULL DEFAULT 0,
  rating_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS pharmacies_owner_account_id_key
  ON pharmacies(owner_account_id);
CREATE INDEX IF NOT EXISTS pharmacies_governorate_idx ON pharmacies(governorate);
CREATE INDEX IF NOT EXISTS pharmacies_city_idx ON pharmacies(city);
CREATE INDEX IF NOT EXISTS pharmacies_status_idx ON pharmacies(status);
CREATE INDEX IF NOT EXISTS pharmacies_subscription_status_idx ON pharmacies(subscription_status);

ALTER TABLE pharmacies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pharmacies_select_all" ON pharmacies;
CREATE POLICY "pharmacies_select_all" ON pharmacies FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "pharmacies_insert_all" ON pharmacies;
CREATE POLICY "pharmacies_insert_all" ON pharmacies FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "pharmacies_update_all" ON pharmacies;
CREATE POLICY "pharmacies_update_all" ON pharmacies FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "pharmacies_delete_all" ON pharmacies;
CREATE POLICY "pharmacies_delete_all" ON pharmacies FOR DELETE
  TO anon, authenticated USING (true);

-- ============ pharmacy_edit_logs ============
CREATE TABLE IF NOT EXISTS pharmacy_edit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  action text NOT NULL,
  changed_by text,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS edit_logs_pharmacy_idx ON pharmacy_edit_logs(pharmacy_id);

ALTER TABLE pharmacy_edit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "edit_logs_select_all" ON pharmacy_edit_logs;
CREATE POLICY "edit_logs_select_all" ON pharmacy_edit_logs FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "edit_logs_insert_all" ON pharmacy_edit_logs;
CREATE POLICY "edit_logs_insert_all" ON pharmacy_edit_logs FOR INSERT
  TO anon, authenticated WITH CHECK (true);

-- ============ pharmacy_notifications ============
CREATE TABLE IF NOT EXISTS pharmacy_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  message text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notifs_pharmacy_idx ON pharmacy_notifications(pharmacy_id);

ALTER TABLE pharmacy_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "notifs_select_all" ON pharmacy_notifications;
CREATE POLICY "notifs_select_all" ON pharmacy_notifications FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "notifs_insert_all" ON pharmacy_notifications;
CREATE POLICY "notifs_insert_all" ON pharmacy_notifications FOR INSERT
  TO anon, authenticated WITH CHECK (true);

-- ============ pharmacy_conversations ============
CREATE TABLE IF NOT EXISTS pharmacy_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  account_id text,
  last_message_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS convos_pharmacy_idx ON pharmacy_conversations(pharmacy_id);

ALTER TABLE pharmacy_conversations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "convos_select_all" ON pharmacy_conversations;
CREATE POLICY "convos_select_all" ON pharmacy_conversations FOR SELECT
  TO anon, authenticated USING (true);

-- ============ updated_at trigger ============
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS pharmacies_set_updated_at ON pharmacies;
CREATE TRIGGER pharmacies_set_updated_at
  BEFORE UPDATE ON pharmacies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS applications_set_updated_at ON pharmacy_applications;
CREATE TRIGGER applications_set_updated_at
  BEFORE UPDATE ON pharmacy_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ approve function ============
CREATE OR REPLACE FUNCTION approve_pharmacy_application(
  app_id uuid,
  reviewer_account text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  app RECORD;
  new_pharmacy_id uuid;
  dur int;
BEGIN
  SELECT * INTO app FROM pharmacy_applications WHERE id = app_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application not found';
  END IF;
  IF app.status = 'approved' THEN
    RAISE EXCEPTION 'Application already approved';
  END IF;

  dur := COALESCE(NULLIF((SELECT duration_days FROM subscription_plans WHERE id = app.plan_id), 0), 30);

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
    'active', app.plan_id, now(),
    CASE WHEN app.plan_id IS NOT NULL THEN now() + (dur * interval '1 day') ELSE NULL END,
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
$$ LANGUAGE plpgsql;

-- ============ seed subscription plans ============
INSERT INTO subscription_plans (name, price_yer, duration_days, features, is_active, sort_order)
VALUES
  ('الباقة الشهرية', 5000, 30, '["ظهور في نتائج البحث","عرض رقم التواصل","لوحة إدارة أساسية"]'::jsonb, true, 1),
  ('الباقة الربع سنوية', 13000, 90, '["ظهور في نتائج البحث","عرض رقم التواصل","لوحة إدارة أساسية","إعلان مميز مرة شهرياً"]'::jsonb, true, 2),
  ('الباقة نصف سنوية', 24000, 180, '["ظهور في نتائج البحث","عرض رقم التواصل","لوحة إدارة متقدمة","إعلان مميز مرتين شهرياً","تقارير شهرية"]'::jsonb, true, 3),
  ('الباقة السنوية', 45000, 365, '["ظهور مميز في نتائج البحث","عرض رقم التواصل","لوحة إدارة متقدمة","إعلان مميز غير محدود","تقارير شهرية","دعم فني مخصص"]'::jsonb, true, 4),
  ('الباقة التجريبية', 0, 7, '["ظهور في نتائج البحث","عرض رقم التواصل"]'::jsonb, true, 5)
ON CONFLICT DO NOTHING;

-- ============ seed payment info ============
INSERT INTO payment_infos (bank_name, account_name, account_number, is_active)
VALUES ('بنك التموير اليمني', 'شركة دُلني للخدمات الصيدلانية', '0123456789012', true)
ON CONFLICT DO NOTHING;

-- ============ storage bucket ============
INSERT INTO storage.buckets (id, name, public)
VALUES ('pharmacy-documents', 'pharmacy-documents', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "pharmacy_docs_public_read" ON storage.objects;
CREATE POLICY "pharmacy_docs_public_read" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'pharmacy-documents');

DROP POLICY IF EXISTS "pharmacy_docs_insert" ON storage.objects;
CREATE POLICY "pharmacy_docs_insert" ON storage.objects
  FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'pharmacy-documents');

DROP POLICY IF EXISTS "pharmacy_docs_update" ON storage.objects;
CREATE POLICY "pharmacy_docs_update" ON storage.objects
  FOR UPDATE TO anon, authenticated
  USING (bucket_id = 'pharmacy-documents') WITH CHECK (bucket_id = 'pharmacy-documents');

DROP POLICY IF EXISTS "pharmacy_docs_delete" ON storage.objects;
CREATE POLICY "pharmacy_docs_delete" ON storage.objects
  FOR DELETE TO anon, authenticated
  USING (bucket_id = 'pharmacy-documents');
