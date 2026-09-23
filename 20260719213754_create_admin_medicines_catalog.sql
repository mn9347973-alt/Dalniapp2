/*
# Dulni Central Medicines Catalog (Approved + Banned)

## Overview
Creates the central medicines database for the Dulni app: an **approved** list (drugs allowed
to be traded) and a **banned** list (drugs prohibited from trade). These are the admin-managed
master catalogs. Pharmacy-specific inventory lives in the existing `medicines` table (per-pharmacy
rows referencing these catalogs by name). The admin dashboard "إدارة الأدوية" section manages
these two lists and the audit log of all operations.

## Context
Dulni uses custom client-side auth (no Supabase Auth). Admin is account id `776695102`. All RLS
policies use `TO anon, authenticated` (the frontend filters by context). This matches the existing
pharmacies/medicines tables.

## Tables Created

1. **approved_medicines** — master catalog of approved drugs
   - id, scientific_name (not null), trade_name (not null), active_ingredient, manufacturer,
     type, concentration, is_paused (bool default false), first_pharmacy_account (text, the
     first pharmacy account that added this drug, if it came from a pharmacy), created_by,
     created_at, updated_at
   - Unique (scientific_name, trade_name) prevents duplicate catalog entries.
2. **banned_medicines** — master catalog of prohibited drugs
   - id, scientific_name (not null), trade_name (not null), active_ingredient, manufacturer,
     type, concentration, ban_reason, created_by, created_at, updated_at
   - Unique (scientific_name, trade_name) prevents duplicates.
3. **medicine_audit_logs** — full history of add/edit/ban/approve operations
   - id, action ('add_approved'|'add_banned'|'edit_approved'|'edit_banned'|'ban'|'approve'|
     'delete_banned'|'pause'|'resume'|'bulk_import_approved'|'bulk_import_banned'),
     list ('approved'|'banned'), medicine_id (nullable, no FK since rows can move between lists),
     scientific_name, trade_name, actor (account id), note, created_at

## Functions
- **move_to_banned(p_medicine_id uuid, p_actor text, p_reason text)** — moves an approved
  medicine into banned_medicines (carrying over its data), deletes it from approved_medicines,
  and removes it from every pharmacy's inventory (medicines table) so it stops appearing
  everywhere. Logs the action. Returns the new banned_medicine id.
- **move_to_approved(p_banned_id uuid, p_actor text)** — moves a banned medicine back into
  approved_medicines (does NOT restore pharmacy inventories automatically — pharmacies can
  re-add it). Logs the action. Returns the new approved_medicine id.
- **check_medicine_banned(p_scientific text, p_trade text)** — returns boolean whether a drug
  is currently in the banned list (by exact name match, case-insensitive). Used by the trigger
  and available for the Excel import validation path.
- **is_medicine_paused_or_banned(p_scientific text, p_trade text)** — returns 'banned' | 'paused'
  | 'ok'. Used to decide visibility in the user search screen (future).

## Trigger
- **medicines_before_insert_check_banned** — BEFORE INSERT on the per-pharmacy `medicines` table.
  If the drug (by scientific_name + trade_name, case-insensitive) exists in banned_medicines,
  the insert is rejected with an error. If it does NOT exist in approved_medicines, a new
  approved_medicines row is auto-created with first_pharmacy_account set to the inserting
  pharmacy's owner account. This implements the "pharmacy adds a new drug → auto-catalog it"
  rule and the "pharmacy cannot add a banned drug" rule at the database level.

## Security (RLS)
All tables: RLS enabled, `TO anon, authenticated` CRUD (single-tenant trust model, consistent
with the rest of the app). Ownership/enforcement is handled by the app + the DB trigger/function.

## Notes
1. Idempotent: IF NOT EXISTS for tables/indexes/functions; DROP IF EXISTS before CREATE POLICY
   and before CREATE TRIGGER.
2. The trigger references approved_medicines/banned_medicines in its body, so those tables must
   exist first (they are created above the trigger in this migration).
3. move_to_banned deletes the approved row and all per-pharmacy inventory rows for that drug to
   guarantee it disappears system-wide immediately. move_to_approved does NOT restore inventory —
   pharmacies re-add it themselves (the approved catalog entry is what allows them to).
4. No data is lost on ban: the drug's metadata moves to banned_medicines; only per-pharmacy
   inventory copies are removed (they can be re-added after approval).
5. updated_at triggers reuse the existing set_updated_at() function.
*/

-- ============ approved_medicines ============
CREATE TABLE IF NOT EXISTS approved_medicines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scientific_name text NOT NULL,
  trade_name text NOT NULL,
  active_ingredient text,
  manufacturer text,
  type text,
  concentration text,
  is_paused boolean NOT NULL DEFAULT false,
  first_pharmacy_account text,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS approved_meds_sci_trade_key
  ON approved_medicines(lower(scientific_name), lower(trade_name));
CREATE INDEX IF NOT EXISTS approved_meds_manufacturer_idx ON approved_medicines(manufacturer);
CREATE INDEX IF NOT EXISTS approved_meds_paused_idx ON approved_medicines(is_paused);
CREATE INDEX IF NOT EXISTS approved_meds_trgm_idx ON approved_medicines USING gin (scientific_name gin_trgm_ops, trade_name gin_trgm_ops);

ALTER TABLE approved_medicines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "approved_meds_select_all" ON approved_medicines;
CREATE POLICY "approved_meds_select_all" ON approved_medicines FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "approved_meds_insert_all" ON approved_medicines;
CREATE POLICY "approved_meds_insert_all" ON approved_medicines FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "approved_meds_update_all" ON approved_medicines;
CREATE POLICY "approved_meds_update_all" ON approved_medicines FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "approved_meds_delete_all" ON approved_medicines;
CREATE POLICY "approved_meds_delete_all" ON approved_medicines FOR DELETE
  TO anon, authenticated USING (true);

DROP TRIGGER IF EXISTS approved_meds_set_updated_at ON approved_medicines;
CREATE TRIGGER approved_meds_set_updated_at
  BEFORE UPDATE ON approved_medicines
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ banned_medicines ============
CREATE TABLE IF NOT EXISTS banned_medicines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scientific_name text NOT NULL,
  trade_name text NOT NULL,
  active_ingredient text,
  manufacturer text,
  type text,
  concentration text,
  ban_reason text,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS banned_meds_sci_trade_key
  ON banned_medicines(lower(scientific_name), lower(trade_name));
CREATE INDEX IF NOT EXISTS banned_meds_trgm_idx ON banned_medicines USING gin (scientific_name gin_trgm_ops, trade_name gin_trgm_ops);

ALTER TABLE banned_medicines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "banned_meds_select_all" ON banned_medicines;
CREATE POLICY "banned_meds_select_all" ON banned_medicines FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "banned_meds_insert_all" ON banned_medicines;
CREATE POLICY "banned_meds_insert_all" ON banned_medicines FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "banned_meds_update_all" ON banned_medicines;
CREATE POLICY "banned_meds_update_all" ON banned_medicines FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "banned_meds_delete_all" ON banned_medicines;
CREATE POLICY "banned_meds_delete_all" ON banned_medicines FOR DELETE
  TO anon, authenticated USING (true);

DROP TRIGGER IF EXISTS banned_meds_set_updated_at ON banned_medicines;
CREATE TRIGGER banned_meds_set_updated_at
  BEFORE UPDATE ON banned_medicines
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ medicine_audit_logs ============
CREATE TABLE IF NOT EXISTS medicine_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL,
  list text NOT NULL DEFAULT 'approved',
  medicine_id uuid,
  scientific_name text,
  trade_name text,
  actor text,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS med_audit_created_idx ON medicine_audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS med_audit_action_idx ON medicine_audit_logs(action);
CREATE INDEX IF NOT EXISTS med_audit_medicine_idx ON medicine_audit_logs(medicine_id);

ALTER TABLE medicine_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "med_audit_select_all" ON medicine_audit_logs;
CREATE POLICY "med_audit_select_all" ON medicine_audit_logs FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "med_audit_insert_all" ON medicine_audit_logs;
CREATE POLICY "med_audit_insert_all" ON medicine_audit_logs FOR INSERT
  TO anon, authenticated WITH CHECK (true);

-- ============ helper functions ============
CREATE OR REPLACE FUNCTION check_medicine_banned(p_scientific text, p_trade text)
RETURNS boolean AS $$
DECLARE
  found boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM banned_medicines
      WHERE lower(scientific_name) = lower(p_scientific)
        AND lower(trade_name) = lower(p_trade)
  ) INTO found;
  RETURN found;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION is_medicine_paused_or_banned(p_scientific text, p_trade text)
RETURNS text AS $$
DECLARE
  banned_found boolean;
  paused_found boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM banned_medicines
      WHERE lower(scientific_name) = lower(p_scientific)
        AND lower(trade_name) = lower(p_trade)
  ) INTO banned_found;
  IF banned_found THEN RETURN 'banned'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM approved_medicines
      WHERE lower(scientific_name) = lower(p_scientific)
        AND lower(trade_name) = lower(p_trade)
        AND is_paused = true
  ) INTO paused_found;
  IF paused_found THEN RETURN 'paused'; END IF;

  RETURN 'ok';
END;
$$ LANGUAGE plpgsql;

-- ============ move functions ============
CREATE OR REPLACE FUNCTION move_to_banned(p_medicine_id uuid, p_actor text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS uuid AS $$
DECLARE
  r RECORD;
  new_id uuid;
BEGIN
  SELECT * INTO r FROM approved_medicines WHERE id = p_medicine_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Approved medicine not found'; END IF;

  INSERT INTO banned_medicines (scientific_name, trade_name, active_ingredient, manufacturer, type, concentration, ban_reason, created_by)
    VALUES (r.scientific_name, r.trade_name, r.active_ingredient, r.manufacturer, r.type, r.concentration, p_reason, p_actor)
    RETURNING id INTO new_id;

  DELETE FROM approved_medicines WHERE id = p_medicine_id;

  -- Remove from every pharmacy's inventory so it disappears system-wide
  DELETE FROM medicines WHERE scientific_name = r.scientific_name AND trade_name = r.trade_name;

  INSERT INTO medicine_audit_logs (action, list, medicine_id, scientific_name, trade_name, actor, note)
    VALUES ('ban', 'banned', new_id, r.scientific_name, r.trade_name, p_actor, p_reason);

  RETURN new_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION move_to_approved(p_banned_id uuid, p_actor text DEFAULT NULL)
RETURNS uuid AS $$
DECLARE
  r RECORD;
  new_id uuid;
BEGIN
  SELECT * INTO r FROM banned_medicines WHERE id = p_banned_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Banned medicine not found'; END IF;

  INSERT INTO approved_medicines (scientific_name, trade_name, active_ingredient, manufacturer, type, concentration, created_by)
    VALUES (r.scientific_name, r.trade_name, r.active_ingredient, r.manufacturer, r.type, r.concentration, p_actor)
    RETURNING id INTO new_id;

  DELETE FROM banned_medicines WHERE id = p_banned_id;

  INSERT INTO medicine_audit_logs (action, list, medicine_id, scientific_name, trade_name, actor, note)
    VALUES ('approve', 'approved', new_id, r.scientific_name, r.trade_name, p_actor, 'اعتماد دواء من القائمة المحظورة');

  RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- ============ trigger: auto-catalog + block banned on pharmacy insert ============
CREATE OR REPLACE FUNCTION medicines_before_insert_check_banned_fn()
RETURNS trigger AS $$
DECLARE
  banned_exists boolean;
  approved_exists boolean;
  pharm RECORD;
BEGIN
  -- Reject if the drug is in the banned list
  SELECT EXISTS (
    SELECT 1 FROM banned_medicines
      WHERE lower(scientific_name) = lower(NEW.scientific_name)
        AND lower(trade_name) = lower(NEW.trade_name)
  ) INTO banned_exists;
  IF banned_exists THEN
    RAISE EXCEPTION 'BANNED_MEDICINE: هذا الدواء محظور ولا يمكن إضافته';
  END IF;

  -- Auto-catalog: if not in approved list, create it and record the first pharmacy
  SELECT EXISTS (
    SELECT 1 FROM approved_medicines
      WHERE lower(scientific_name) = lower(NEW.scientific_name)
        AND lower(trade_name) = lower(NEW.trade_name)
  ) INTO approved_exists;

  IF NOT approved_exists THEN
    SELECT owner_account_id INTO pharm FROM pharmacies WHERE id = NEW.pharmacy_id;
    INSERT INTO approved_medicines (scientific_name, trade_name, manufacturer, type, concentration, first_pharmacy_account, created_by)
      VALUES (NEW.scientific_name, NEW.trade_name, NEW.manufacturer, NEW.type, NEW.concentration, pharm.owner_account_id, pharm.owner_account_id);
    INSERT INTO medicine_audit_logs (action, list, scientific_name, trade_name, actor, note)
      VALUES ('add_approved', 'approved', NEW.scientific_name, NEW.trade_name, pharm.owner_account_id, 'إضافة تلقائية من صيدلية');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS medicines_before_insert_check_banned ON medicines;
CREATE TRIGGER medicines_before_insert_check_banned
  BEFORE INSERT ON medicines
  FOR EACH ROW EXECUTE FUNCTION medicines_before_insert_check_banned_fn();

-- ============ audit trigger helper for approved edits ============
CREATE OR REPLACE FUNCTION log_approved_edit()
RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    INSERT INTO medicine_audit_logs (action, list, medicine_id, scientific_name, trade_name, actor, note)
      VALUES ('edit_approved', 'approved', NEW.id, NEW.scientific_name, NEW.trade_name, NULL, 'تعديل بيانات دواء معتمد');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS approved_meds_log_edit ON approved_medicines;
CREATE TRIGGER approved_meds_log_edit
  AFTER UPDATE ON approved_medicines
  FOR EACH ROW EXECUTE FUNCTION log_approved_edit();
