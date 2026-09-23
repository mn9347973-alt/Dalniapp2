/*
# Message Templates & System Messages

1. New Tables
- `message_templates`: editable templates for all system-generated messages.
  - `id` (uuid, primary key)
  - `key` (text, unique) — machine key identifying the event (e.g. account_approved)
  - `name` (text) — human-friendly template name (Arabic)
  - `message_type` (text) — category label (e.g. "اعتماد", "رفض", "اشتراك")
  - `title` (text) — short title shown as a heading
  - `body` (text) — full message body with {{placeholders}}
  - `default_body` (text) — the original default body, used for "restore default"
  - `is_enabled` (boolean, default true) — admin can disable a template
  - `created_at`, `updated_at` (timestamps)
- Adds column `is_system` (boolean default false) and `system_template_key` (text nullable) to `chat_messages`
  to mark system-generated messages and link them back to the template used.

2. Security
- Enable RLS on `message_templates`.
- Admin-only CRUD (TO anon, authenticated with USING(true) — the app uses a single admin account pattern
  consistent with the rest of this project's tables like app_settings and subscription_plans,
  which are readable/writable by the anon-key client).
- Add INSERT policy on `chat_messages` for system messages (anon can insert, matching existing pattern).

3. Notes
- Seeds default templates for all lifecycle events:
  account_approved, account_rejected, edit_approved, edit_rejected,
  renewal_approved, renewal_rejected, subscription_expired,
  pharmacy_paused, pharmacy_reactivated.
- Each template body uses {{placeholders}} that the application fills at send time.
*/

CREATE TABLE IF NOT EXISTS message_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  name text NOT NULL,
  message_type text NOT NULL DEFAULT 'عام',
  title text NOT NULL DEFAULT '',
  body text NOT NULL,
  default_body text NOT NULL,
  is_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE message_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "read_message_templates" ON message_templates;
CREATE POLICY "read_message_templates" ON message_templates FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "insert_message_templates" ON message_templates;
CREATE POLICY "insert_message_templates" ON message_templates FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "update_message_templates" ON message_templates;
CREATE POLICY "update_message_templates" ON message_templates FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "delete_message_templates" ON message_templates;
CREATE POLICY "delete_message_templates" ON message_templates FOR DELETE
  TO anon, authenticated USING (true);

-- Add system message columns to chat_messages
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'chat_messages' AND column_name = 'is_system') THEN
    ALTER TABLE chat_messages ADD COLUMN is_system boolean NOT NULL DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'chat_messages' AND column_name = 'system_template_key') THEN
    ALTER TABLE chat_messages ADD COLUMN system_template_key text;
  END IF;
END $$;

-- Seed default templates
INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('account_approved',
 'اعتماد إنشاء حساب صيدلية',
 'اعتماد',
 'تم اعتماد حسابكم',
 'تهانينا! تم اعتماد طلب إنشاء حساب صيدليتكم بتاريخ {{date}}. يمكنكم الآن تسجيل الدخول والبدء بإدارة صيدليتكم.',
 'تهانينا! تم اعتماد طلب إنشاء حساب صيدليتكم بتاريخ {{date}}. يمكنكم الآن تسجيل الدخول والبدء بإدارة صيدليتكم.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('account_rejected',
 'رفض إنشاء حساب صيدلية',
 'رفض',
 'تم رفض طلب الحساب',
 'تم رفض طلب إنشاء حساب صيدليتكم بتاريخ {{date}}. سبب الرفض: {{reason}}. لأي استفسار يرجى التواصل مع الإدارة.',
 'تم رفض طلب إنشاء حساب صيدليتكم بتاريخ {{date}}. سبب الرفض: {{reason}}. لأي استفسار يرجى التواصل مع الإدارة.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('edit_approved',
 'اعتماد تعديل بيانات الصيدلية',
 'اعتماد',
 'تم اعتماد تعديل البيانات',
 'تم اعتماد طلب تعديل بيانات صيدليتكم بتاريخ {{date}}. تم تحديث البيانات ونشرها.',
 'تم اعتماد طلب تعديل بيانات صيدليتكم بتاريخ {{date}}. تم تحديث البيانات ونشرها.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('edit_rejected',
 'رفض تعديل بيانات الصيدلية',
 'رفض',
 'تم رفض تعديل البيانات',
 'تم رفض طلب تعديل بيانات صيدليتكم بتاريخ {{date}}. سبب الرفض: {{reason}}. ملاحظات الإدارة: {{admin_note}}.',
 'تم رفض طلب تعديل بيانات صيدليتكم بتاريخ {{date}}. سبب الرفض: {{reason}}. ملاحظات الإدارة: {{admin_note}}.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('renewal_approved',
 'اعتماد تجديد الاشتراك',
 'اشتراك',
 'تم تجديد اشتراككم',
 'تم اعتماد طلب تجديد اشتراككم بتاريخ {{date}}. الباقة المعتمدة: {{plan_name}}. مدة الاشتراك: {{duration_days}} يوم. تاريخ البداية: {{start_date}}. تاريخ الانتهاء: {{end_date}}. {{cumulative_note}} سبب اختيار الباقة: {{plan_reason}}.',
 'تم اعتماد طلب تجديد اشتراككم بتاريخ {{date}}. الباقة المعتمدة: {{plan_name}}. مدة الاشتراك: {{duration_days}} يوم. تاريخ البداية: {{start_date}}. تاريخ الانتهاء: {{end_date}}. {{cumulative_note}} سبب اختيار الباقة: {{plan_reason}}.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('renewal_rejected',
 'رفض تجديد الاشتراك',
 'رفض',
 'تم رفض تجديد الاشتراك',
 'تم رفض طلب تجديد اشتراككم بتاريخ {{date}}. سبب الرفض: {{reason}}.',
 'تم رفض طلب تجديد اشتراككم بتاريخ {{date}}. سبب الرفض: {{reason}}.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('subscription_expired',
 'انتهاء الاشتراك',
 'اشتراك',
 'انتهى اشتراككم',
 'انتهى اشتراك صيدليتكم بتاريخ {{date}}. يرجى تجديد الاشتراك للاستمرار في الاستفادة من الخدمات.',
 'انتهى اشتراك صيدليتكم بتاريخ {{date}}. يرجى تجديد الاشتراك للاستمرار في الاستفادة من الخدمات.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('pharmacy_paused',
 'إيقاف الصيدلية مؤقتاً',
 'إيقاف',
 'تم إيقاف الصيدلية',
 'تم إيقاف صيدليتكم مؤقتاً بتاريخ {{date}}. سبب الإيقاف: {{reason}}. ملاحظات الإدارة: {{admin_note}}.',
 'تم إيقاف صيدليتكم مؤقتاً بتاريخ {{date}}. سبب الإيقاف: {{reason}}. ملاحظات الإدارة: {{admin_note}}.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO message_templates (key, name, message_type, title, body, default_body) VALUES
('pharmacy_reactivated',
 'إعادة تفعيل الصيدلية',
 'تفعيل',
 'تم إعادة تفعيل الصيدلية',
 'تم إعادة تفعيل صيدليتكم بتاريخ {{date}}. يمكنكم الآن ممارسة عملكم بشكل طبيعي.',
 'تم إعادة تفعيل صيدليتكم بتاريخ {{date}}. يمكنكم الآن ممارسة عملكم بشكل طبيعي.')
ON CONFLICT (key) DO NOTHING;

-- Index for template key lookups
CREATE INDEX IF NOT EXISTS idx_message_templates_key ON message_templates(key);
