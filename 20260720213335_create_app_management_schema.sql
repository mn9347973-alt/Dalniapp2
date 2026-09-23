/*
# Dulni App Management Schema

## Overview
Creates the backend tables for the "إدارة التطبيق" (App Management) section of the admin
dashboard. This section manages static pages content, general app data, app update settings,
subscription settings, and payment methods — all editable from the admin panel without code
changes.

## Context
Dulni uses a custom client-side auth system (no Supabase Auth). All RLS policies use
`TO anon, authenticated` with `USING (true)` — single-tenant trust model consistent with
existing tables (subscription_plans, payment_infos, pharmacies, etc.).

## Tables Created
1. **static_pages** — editable static pages (about, privacy, payment policy, terms, FAQ, contact)
   - id, slug (unique), title, content (text), is_published, sort_order, created_at, updated_at
2. **app_settings** — key-value store for ALL general/subscription/update settings (extensible)
   - id, key (unique), value (jsonb), updated_at
   - New settings can be added by inserting new rows — no schema changes needed.
3. **payment_methods** — approved payment methods shown to pharmacies during registration/renewal
   - id, name, description, is_active, sort_order, created_at

## Storage
- `app-assets` bucket created for app logo/icon uploads (public read, anon/authenticated write).

## Seeded Data
- 6 static pages with default Arabic content
- 17 app settings keys (app name, logo, icon, email, phone, contact numbers, social links,
  subscription grace days, expiry messages, subscriptions enabled, current version, update
  message, update type, force update enabled, min allowed version)
- 2 payment methods (تحويل بنكي, كاش)

## Notes
1. Existing `subscription_plans` and `payment_infos` tables are reused for plans and bank accounts.
2. `app_settings` uses jsonb values for maximum extensibility — new settings added without schema changes.
3. Idempotent: IF NOT EXISTS for tables/indexes; DROP IF EXISTS before CREATE POLICY.
4. updated_at triggers reuse the existing `set_updated_at()` function from the first migration.
*/

-- ============ static_pages ============
CREATE TABLE IF NOT EXISTS static_pages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text UNIQUE NOT NULL,
  title text NOT NULL,
  content text NOT NULL DEFAULT '',
  is_published boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE static_pages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "static_pages_select_all" ON static_pages;
CREATE POLICY "static_pages_select_all" ON static_pages FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "static_pages_insert_all" ON static_pages;
CREATE POLICY "static_pages_insert_all" ON static_pages FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "static_pages_update_all" ON static_pages;
CREATE POLICY "static_pages_update_all" ON static_pages FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "static_pages_delete_all" ON static_pages;
CREATE POLICY "static_pages_delete_all" ON static_pages FOR DELETE
  TO anon, authenticated USING (true);

DROP TRIGGER IF EXISTS static_pages_set_updated_at ON static_pages;
CREATE TRIGGER static_pages_set_updated_at
  BEFORE UPDATE ON static_pages
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ app_settings ============
CREATE TABLE IF NOT EXISTS app_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "app_settings_select_all" ON app_settings;
CREATE POLICY "app_settings_select_all" ON app_settings FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "app_settings_insert_all" ON app_settings;
CREATE POLICY "app_settings_insert_all" ON app_settings FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "app_settings_update_all" ON app_settings;
CREATE POLICY "app_settings_update_all" ON app_settings FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "app_settings_delete_all" ON app_settings;
CREATE POLICY "app_settings_delete_all" ON app_settings FOR DELETE
  TO anon, authenticated USING (true);

DROP TRIGGER IF EXISTS app_settings_set_updated_at ON app_settings;
CREATE TRIGGER app_settings_set_updated_at
  BEFORE UPDATE ON app_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ payment_methods ============
CREATE TABLE IF NOT EXISTS payment_methods (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE payment_methods ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "payment_methods_select_all" ON payment_methods;
CREATE POLICY "payment_methods_select_all" ON payment_methods FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "payment_methods_insert_all" ON payment_methods;
CREATE POLICY "payment_methods_insert_all" ON payment_methods FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "payment_methods_update_all" ON payment_methods;
CREATE POLICY "payment_methods_update_all" ON payment_methods FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "payment_methods_delete_all" ON payment_methods;
CREATE POLICY "payment_methods_delete_all" ON payment_methods FOR DELETE
  TO anon, authenticated USING (true);

-- ============ seed static pages ============
INSERT INTO static_pages (slug, title, content, is_published, sort_order) VALUES
  ('about', 'من نحن', 'دُلني هو تطبيق متخصص في ربط الصيدليات بالمستخدمين، يوفر معلومات دقيقة ومحدثة عن الأدوية وأماكن توفرها في الصيدليات القريبة.', true, 1),
  ('privacy', 'سياسة الخصوصية', 'نحن في دُلني نحترم خصوصية مستخدمي التطبيق ونلتزم بحماية بياناتهم الشخصية وعدم مشاركتها مع أي طرف ثالث دون موافقتهم.', true, 2),
  ('payment-policy', 'سياسة الدفع والاشتراك', 'يتم دفع رسوم الاشتراك عبر الحسابات البنكية المعتمدة الموضحة في صفحة الدفع. الاشتراك ساري المدة المحددة في الباقة المختارة.', true, 3),
  ('terms', 'شروط وأحكام الاستخدام', 'باستخدامك لتطبيق دُلني فإنك توافق على الالتزام بالشروط والأحكام التالية. يُمنع استخدام التطبيق لأغراض غير قانونية أو مخالفة للآداب العامة.', true, 4),
  ('faq', 'الأسئلة الشائعة', 'تجد هنا إجابات للأسئلة الأكثر شيوعاً حول استخدام التطبيق والاشتراك والخدمات المتاحة.', true, 5),
  ('contact', 'تواصل معنا', 'يمكنك التواصل معنا عبر البريد الإلكتروني أو الهاتف أو وسائل التواصل الاجتماعي الموضحة أدناه.', true, 6)
ON CONFLICT (slug) DO NOTHING;

-- ============ seed app settings ============
INSERT INTO app_settings (key, value) VALUES
  ('app_name', '"دُلني"'::jsonb),
  ('app_logo', 'null'::jsonb),
  ('app_icon', 'null'::jsonb),
  ('official_email', '"info@dulni.ye"'::jsonb),
  ('customer_service_number', '"776695102"'::jsonb),
  ('contact_numbers', '["776695102"]'::jsonb),
  ('available_contact_methods', '["whatsapp","phone","email"]'::jsonb),
  ('social_links', '{"facebook":"","twitter":"","instagram":"","telegram":""}'::jsonb),
  ('subscription_grace_days', '7'::jsonb),
  ('expiry_warning_message', '"اشتراكك على وشك الانتهاء، يرجى التجديد قبل انتهائه"'::jsonb),
  ('expiry_final_message', '"انتهى اشتراكك، يرجى التجديد لمواصلة استخدام الخدمة"'::jsonb),
  ('subscriptions_enabled', 'true'::jsonb),
  ('current_version', '"1.0.0"'::jsonb),
  ('update_message', '""'::jsonb),
  ('update_type', '"optional"'::jsonb),
  ('force_update_enabled', 'false'::jsonb),
  ('min_allowed_version', '"1.0.0"'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ============ seed payment methods ============
INSERT INTO payment_methods (name, description, is_active, sort_order) VALUES
  ('تحويل بنكي', 'تحويل عبر الحسابات البنكية المعتمدة', true, 1),
  ('كاش', 'دفع نقدي عند المراجعة', true, 2)
ON CONFLICT DO NOTHING;

-- ============ app-assets storage bucket ============
INSERT INTO storage.buckets (id, name, public)
VALUES ('app-assets', 'app-assets', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "app_assets_public_read" ON storage.objects;
CREATE POLICY "app_assets_public_read" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'app-assets');

DROP POLICY IF EXISTS "app_assets_insert" ON storage.objects;
CREATE POLICY "app_assets_insert" ON storage.objects
  FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'app-assets');

DROP POLICY IF EXISTS "app_assets_update" ON storage.objects;
CREATE POLICY "app_assets_update" ON storage.objects
  FOR UPDATE TO anon, authenticated
  USING (bucket_id = 'app-assets') WITH CHECK (bucket_id = 'app-assets');

DROP POLICY IF EXISTS "app_assets_delete" ON storage.objects;
CREATE POLICY "app_assets_delete" ON storage.objects
  FOR DELETE TO anon, authenticated
  USING (bucket_id = 'app-assets');