/*
# Dulni My-Pharmacy Management Schema

## Overview
Adds the backend tables supporting the "إدارة صيدليتي" (My Pharmacy Management) page for
pharmacy owners in the Dulni app. These tables are also consumed by corresponding admin
dashboard sections (medicines, renewals, chat, edit requests) — admin wiring is a separate task.

## Context
Dulni uses a custom client-side auth system (no Supabase Auth): users log in with a 9-digit
account id; admin is `776695102`. The 9-digit id is stored as `owner_account_id` on pharmacies.
All RLS policies use `TO anon, authenticated` and the frontend filters rows by the owning
pharmacy's account id. There is no Supabase Auth session, so ownership is enforced by the app
querying with the correct `pharmacy_id` / `account_id`. This is consistent with the existing
pharmacies/pharmacy_applications tables.

## Tables Created
1. medicines — pharmacy inventory drugs
2. subscription_renewals — owner renewal requests awaiting admin review
3. chat_messages — owner <-> admin support messages
4. chat_daily_counters — per-pharmacy per-day send counter (5 msg/day limit)
5. pharmacy_edit_requests — owner edit requests awaiting admin approval

## Functions
- send_pharmacy_message — inserts a message, enforces 5/day limit via chat_daily_counters
- approve_subscription_renewal — extends pharmacy subscription_ends_at by plan duration
- apply_pharmacy_edit_request — applies requested_changes JSONB onto the pharmacies row

## Security (RLS)
All tables enable RLS with `TO anon, authenticated` CRUD (single-tenant trust model).

## Notes
1. pg_trgm extension enabled first so the medicines GIN trigram index compiles.
2. medicines.is_visible toggles pause/visibility for users; status is availability enum.
3. Idempotent: IF NOT EXISTS for tables/indexes; DROP IF EXISTS before CREATE POLICY.
4. updated_at triggers reuse the existing set_updated_at() function.
5. Adds about text column to pharmacies (idempotent DO block).
*/

-- pg_trgm must exist before the GIN trigram index
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============ medicines ============
CREATE TABLE IF NOT EXISTS medicines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  scientific_name text NOT NULL,
  trade_name text NOT NULL,
  manufacturer text,
  type text,
  concentration text,
  status text NOT NULL DEFAULT 'available',
  is_visible boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS medicines_pharmacy_trade_sci_key
  ON medicines(pharmacy_id, trade_name, scientific_name);
CREATE INDEX IF NOT EXISTS medicines_pharmacy_idx ON medicines(pharmacy_id);
CREATE INDEX IF NOT EXISTS medicines_status_idx ON medicines(status);
CREATE INDEX IF NOT EXISTS medicines_trgm_name_idx ON medicines USING gin (scientific_name gin_trgm_ops);

ALTER TABLE medicines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "medicines_select_all" ON medicines;
CREATE POLICY "medicines_select_all" ON medicines FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "medicines_insert_all" ON medicines;
CREATE POLICY "medicines_insert_all" ON medicines FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "medicines_update_all" ON medicines;
CREATE POLICY "medicines_update_all" ON medicines FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "medicines_delete_all" ON medicines;
CREATE POLICY "medicines_delete_all" ON medicines FOR DELETE
  TO anon, authenticated USING (true);

DROP TRIGGER IF EXISTS medicines_set_updated_at ON medicines;
CREATE TRIGGER medicines_set_updated_at
  BEFORE UPDATE ON medicines
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ subscription_renewals ============
CREATE TABLE IF NOT EXISTS subscription_renewals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  plan_id uuid REFERENCES subscription_plans(id) ON DELETE SET NULL,
  payment_slip_path text,
  status text NOT NULL DEFAULT 'pending',
  rejection_reason text,
  reviewed_by text,
  reviewed_at timestamptz,
  submitted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS renewals_pharmacy_idx ON subscription_renewals(pharmacy_id);
CREATE INDEX IF NOT EXISTS renewals_status_idx ON subscription_renewals(status);

ALTER TABLE subscription_renewals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "renewals_select_all" ON subscription_renewals;
CREATE POLICY "renewals_select_all" ON subscription_renewals FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "renewals_insert_all" ON subscription_renewals;
CREATE POLICY "renewals_insert_all" ON subscription_renewals FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "renewals_update_all" ON subscription_renewals;
CREATE POLICY "renewals_update_all" ON subscription_renewals FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "renewals_delete_all" ON subscription_renewals;
CREATE POLICY "renewals_delete_all" ON subscription_renewals FOR DELETE
  TO anon, authenticated USING (true);

DROP TRIGGER IF EXISTS renewals_set_updated_at ON subscription_renewals;
CREATE TRIGGER renewals_set_updated_at
  BEFORE UPDATE ON subscription_renewals
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ chat_messages ============
CREATE TABLE IF NOT EXISTS chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  sender text NOT NULL DEFAULT 'pharmacy',
  body text NOT NULL,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_pharmacy_idx ON chat_messages(pharmacy_id, created_at);

ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "chat_select_all" ON chat_messages;
CREATE POLICY "chat_select_all" ON chat_messages FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "chat_insert_all" ON chat_messages;
CREATE POLICY "chat_insert_all" ON chat_messages FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "chat_update_all" ON chat_messages;
CREATE POLICY "chat_update_all" ON chat_messages FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

-- ============ chat_daily_counters ============
CREATE TABLE IF NOT EXISTS chat_daily_counters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  day date NOT NULL DEFAULT current_date,
  count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS chat_counter_pharmacy_day_key
  ON chat_daily_counters(pharmacy_id, day);

ALTER TABLE chat_daily_counters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "chat_counter_select_all" ON chat_daily_counters;
CREATE POLICY "chat_counter_select_all" ON chat_daily_counters FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "chat_counter_insert_all" ON chat_daily_counters;
CREATE POLICY "chat_counter_insert_all" ON chat_daily_counters FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "chat_counter_update_all" ON chat_daily_counters;
CREATE POLICY "chat_counter_update_all" ON chat_daily_counters FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

-- ============ pharmacy_edit_requests ============
CREATE TABLE IF NOT EXISTS pharmacy_edit_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  requested_changes jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending',
  rejection_reason text,
  reviewed_by text,
  reviewed_at timestamptz,
  submitted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS edit_requests_pharmacy_idx ON pharmacy_edit_requests(pharmacy_id);
CREATE INDEX IF NOT EXISTS edit_requests_status_idx ON pharmacy_edit_requests(status);
CREATE UNIQUE INDEX IF NOT EXISTS edit_requests_pending_per_pharmacy_key
  ON pharmacy_edit_requests(pharmacy_id) WHERE status = 'pending';

ALTER TABLE pharmacy_edit_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "edit_requests_select_all" ON pharmacy_edit_requests;
CREATE POLICY "edit_requests_select_all" ON pharmacy_edit_requests FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "edit_requests_insert_all" ON pharmacy_edit_requests;
CREATE POLICY "edit_requests_insert_all" ON pharmacy_edit_requests FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "edit_requests_update_all" ON pharmacy_edit_requests;
CREATE POLICY "edit_requests_update_all" ON pharmacy_edit_requests FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "edit_requests_delete_all" ON pharmacy_edit_requests;
CREATE POLICY "edit_requests_delete_all" ON pharmacy_edit_requests FOR DELETE
  TO anon, authenticated USING (true);

DROP TRIGGER IF EXISTS edit_requests_set_updated_at ON pharmacy_edit_requests;
CREATE TRIGGER edit_requests_set_updated_at
  BEFORE UPDATE ON pharmacy_edit_requests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ functions ============
CREATE OR REPLACE FUNCTION send_pharmacy_message(p_pharmacy_id uuid, p_body text)
RETURNS uuid AS $$
DECLARE
  msg_id uuid;
  today_count integer;
BEGIN
  IF trim(coalesce(p_body, '')) = '' THEN
    RAISE EXCEPTION 'Body cannot be empty';
  END IF;

  SELECT count INTO today_count
    FROM chat_daily_counters
    WHERE pharmacy_id = p_pharmacy_id AND day = current_date;

  IF today_count IS NULL THEN
    INSERT INTO chat_daily_counters (pharmacy_id, day, count) VALUES (p_pharmacy_id, current_date, 1);
  ELSIF today_count >= 5 THEN
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION approve_subscription_renewal(p_renewal_id uuid, p_reviewer text DEFAULT NULL)
RETURNS timestamptz AS $$
DECLARE
  r RECORD;
  dur int;
  base_ts timestamptz;
  new_end timestamptz;
BEGIN
  SELECT * INTO r FROM subscription_renewals WHERE id = p_renewal_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Renewal not found'; END IF;
  IF r.status = 'approved' THEN RAISE EXCEPTION 'Renewal already approved'; END IF;

  dur := COALESCE(NULLIF((SELECT duration_days FROM subscription_plans WHERE id = r.plan_id), 0), 30);

  SELECT subscription_ends_at INTO base_ts FROM pharmacies WHERE id = r.pharmacy_id;
  IF base_ts IS NOT NULL AND base_ts > now() THEN
    new_end := base_ts + (dur * interval '1 day');
  ELSE
    new_end := now() + (dur * interval '1 day');
  END IF;

  UPDATE pharmacies
    SET subscription_ends_at = new_end,
        subscription_status = 'active',
        subscription_plan_id = COALESCE(r.plan_id, subscription_plan_id),
        subscription_started_at = COALESCE(subscription_started_at, now()),
        updated_at = now()
    WHERE id = r.pharmacy_id;

  UPDATE subscription_renewals
    SET status = 'approved', reviewed_by = p_reviewer, reviewed_at = now(), updated_at = now()
    WHERE id = p_renewal_id;

  RETURN new_end;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_pharmacy_edit_request(p_request_id uuid, p_reviewer text DEFAULT NULL)
RETURNS uuid AS $$
DECLARE
  r RECORD;
  ch jsonb;
  new_about text;
  col text;
BEGIN
  SELECT * INTO r FROM pharmacy_edit_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found'; END IF;
  IF r.status = 'approved' THEN RAISE EXCEPTION 'Request already approved'; END IF;

  ch := r.requested_changes;

  IF ch ? 'name' THEN
    UPDATE pharmacies SET name = (ch->>'name'), updated_at = now() WHERE id = r.pharmacy_id;
  END IF;
  IF ch ? 'address' THEN
    UPDATE pharmacies SET address = (ch->>'address'), updated_at = now() WHERE id = r.pharmacy_id;
  END IF;
  IF ch ? 'latitude' THEN
    UPDATE pharmacies SET latitude = (ch->>'latitude')::double precision, updated_at = now() WHERE id = r.pharmacy_id;
  END IF;
  IF ch ? 'longitude' THEN
    UPDATE pharmacies SET longitude = (ch->>'longitude')::double precision, updated_at = now() WHERE id = r.pharmacy_id;
  END IF;
  IF ch ? 'phone' THEN
    UPDATE pharmacies SET phone = (ch->>'phone'), updated_at = now() WHERE id = r.pharmacy_id;
  END IF;
  IF ch ? 'whatsapp' THEN
    UPDATE pharmacies SET whatsapp = (ch->>'whatsapp'), updated_at = now() WHERE id = r.pharmacy_id;
  END IF;
  IF ch ? 'facade_image_path' THEN
    UPDATE pharmacies SET facade_image_path = (ch->>'facade_image_path'), updated_at = now() WHERE id = r.pharmacy_id;
  END IF;

  SELECT column_name INTO col FROM information_schema.columns
    WHERE table_name = 'pharmacies' AND column_name = 'about';
  IF col IS NULL THEN
    ALTER TABLE pharmacies ADD COLUMN about text;
  END IF;
  IF ch ? 'about' THEN
    new_about := (ch->>'about');
    UPDATE pharmacies SET about = new_about, updated_at = now() WHERE id = r.pharmacy_id;
  END IF;

  UPDATE pharmacy_edit_requests
    SET status = 'approved', reviewed_by = p_reviewer, reviewed_at = now(), updated_at = now()
    WHERE id = p_request_id;

  INSERT INTO pharmacy_edit_logs (pharmacy_id, action, changed_by, note)
    VALUES (r.pharmacy_id, 'edit_request_approved', p_reviewer, 'اعتماد طلب تعديل بيانات');

  RETURN r.pharmacy_id;
END;
$$ LANGUAGE plpgsql;

-- ============ add about column to pharmacies (idempotent) ============
DO $$
DECLARE
  has_about boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'pharmacies' AND column_name = 'about'
  ) INTO has_about;
  IF NOT has_about THEN
    ALTER TABLE pharmacies ADD COLUMN about text;
  END IF;
END $$;
