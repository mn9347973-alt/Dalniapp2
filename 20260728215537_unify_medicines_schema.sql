/*
# Unify medicines schema — add missing columns, indexes, and fix auto-catalog trigger

## Problem
The `medicines`, `approved_medicines`, and `banned_medicines` tables are missing
7 columns that the application code (TypeScript types, forms, search RPCs) already
expects: `dosage`, `category`, `description`, `country`, `agent`, `trade_name_en`,
`scientific_name_en`, `manufacturer_en`. The `medicines` table is also missing
`active_ingredient` which exists on the catalog tables. These columns were added
manually outside migrations, causing schema drift — fresh deployments would break.

## Changes

### 1. Add missing columns to `medicines` (pharmacy inventory)
- `active_ingredient` text — active ingredient (matches catalog tables)
- `dosage` text — dosage information
- `category` text — medicine category
- `description` text — medicine description
- `country` text — country of manufacture
- `agent` text — local agent
- `trade_name_en` text — English trade name
- `scientific_name_en` text — English scientific name
- `manufacturer_en` text — English manufacturer name

### 2. Add missing columns to `approved_medicines` (central catalog)
- `dosage`, `category`, `description`, `country`, `agent`,
  `trade_name_en`, `scientific_name_en`, `manufacturer_en`

### 3. Add missing columns to `banned_medicines` (prohibited catalog)
- `dosage`, `category`, `description`, `country`, `agent`,
  `trade_name_en`, `scientific_name_en`, `manufacturer_en`

### 4. Add trigram indexes for search performance
- `medicines`: GIN trigram on `trade_name` (scientific_name already indexed)
- `approved_medicines`: GIN trigram on `trade_name_en` and `scientific_name_en`
  (trade_name and scientific_name already indexed)

### 5. Update auto-catalog trigger function
- The `medicines_before_insert_check_banned` trigger auto-creates an approved_medicines
  row when a pharmacy adds a new drug. The old version only copied 5 fields.
- Updated to copy ALL enriched fields: active_ingredient, dosage, category,
  description, country, agent, trade_name_en, scientific_name_en, manufacturer_en.

### 6. Add `admin_session_timeout_minutes` to `app_settings`
- Default value: 1 (one minute)
- Used by the admin panel to auto-logout after inactivity

## Security
- No RLS policy changes — existing policies remain intact.
- All columns are nullable (except where already NOT NULL) to preserve existing data.

## Important Notes
1. All column additions use `IF NOT EXISTS` to be safe on re-run.
2. Indexes use `IF NOT EXISTS`.
3. The trigger function is replaced with `CREATE OR REPLACE FUNCTION`.
4. No data is lost — only additive changes.
*/

-- ============ 1. Add missing columns to `medicines` ============
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'active_ingredient') THEN
    ALTER TABLE medicines ADD COLUMN active_ingredient text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'dosage') THEN
    ALTER TABLE medicines ADD COLUMN dosage text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'category') THEN
    ALTER TABLE medicines ADD COLUMN category text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'description') THEN
    ALTER TABLE medicines ADD COLUMN description text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'country') THEN
    ALTER TABLE medicines ADD COLUMN country text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'agent') THEN
    ALTER TABLE medicines ADD COLUMN agent text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'trade_name_en') THEN
    ALTER TABLE medicines ADD COLUMN trade_name_en text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'scientific_name_en') THEN
    ALTER TABLE medicines ADD COLUMN scientific_name_en text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'medicines' AND column_name = 'manufacturer_en') THEN
    ALTER TABLE medicines ADD COLUMN manufacturer_en text;
  END IF;
END $$;

-- ============ 2. Add missing columns to `approved_medicines` ============
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'approved_medicines' AND column_name = 'dosage') THEN
    ALTER TABLE approved_medicines ADD COLUMN dosage text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'approved_medicines' AND column_name = 'category') THEN
    ALTER TABLE approved_medicines ADD COLUMN category text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'approved_medicines' AND column_name = 'description') THEN
    ALTER TABLE approved_medicines ADD COLUMN description text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'approved_medicines' AND column_name = 'country') THEN
    ALTER TABLE approved_medicines ADD COLUMN country text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'approved_medicines' AND column_name = 'agent') THEN
    ALTER TABLE approved_medicines ADD COLUMN agent text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'approved_medicines' AND column_name = 'trade_name_en') THEN
    ALTER TABLE approved_medicines ADD COLUMN trade_name_en text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'approved_medicines' AND column_name = 'scientific_name_en') THEN
    ALTER TABLE approved_medicines ADD COLUMN scientific_name_en text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'approved_medicines' AND column_name = 'manufacturer_en') THEN
    ALTER TABLE approved_medicines ADD COLUMN manufacturer_en text;
  END IF;
END $$;

-- ============ 3. Add missing columns to `banned_medicines` ============
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'banned_medicines' AND column_name = 'dosage') THEN
    ALTER TABLE banned_medicines ADD COLUMN dosage text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'banned_medicines' AND column_name = 'category') THEN
    ALTER TABLE banned_medicines ADD COLUMN category text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'banned_medicines' AND column_name = 'description') THEN
    ALTER TABLE banned_medicines ADD COLUMN description text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'banned_medicines' AND column_name = 'country') THEN
    ALTER TABLE banned_medicines ADD COLUMN country text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'banned_medicines' AND column_name = 'agent') THEN
    ALTER TABLE banned_medicines ADD COLUMN agent text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'banned_medicines' AND column_name = 'trade_name_en') THEN
    ALTER TABLE banned_medicines ADD COLUMN trade_name_en text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'banned_medicines' AND column_name = 'scientific_name_en') THEN
    ALTER TABLE banned_medicines ADD COLUMN scientific_name_en text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'banned_medicines' AND column_name = 'manufacturer_en') THEN
    ALTER TABLE banned_medicines ADD COLUMN manufacturer_en text;
  END IF;
END $$;

-- ============ 4. Add trigram indexes for search performance ============
CREATE INDEX IF NOT EXISTS medicines_trade_name_trgm
  ON medicines USING gin (trade_name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS approved_medicines_trade_name_en_trgm
  ON approved_medicines USING gin (trade_name_en gin_trgm_ops);

CREATE INDEX IF NOT EXISTS approved_medicines_scientific_name_en_trgm
  ON approved_medicines USING gin (scientific_name_en gin_trgm_ops);

-- ============ 5. Update auto-catalog trigger to copy all enriched fields ============
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
  -- Check if medicine is banned
  SELECT count(*) INTO banned_count
  FROM banned_medicines
  WHERE lower(scientific_name) = lower(NEW.scientific_name)
    AND lower(trade_name) = lower(NEW.trade_name);

  IF banned_count > 0 THEN
    RAISE EXCEPTION 'BANNED_MEDICINE: هذا الدواء محظور ولا يمكن إضافته';
  END IF;

  -- Check if already in approved catalog
  SELECT count(*) INTO approved_count
  FROM approved_medicines
  WHERE lower(scientific_name) = lower(NEW.scientific_name)
    AND lower(trade_name) = lower(NEW.trade_name);

  -- If not in approved catalog, auto-create entry with all enriched fields
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

-- ============ 6. Add admin_session_timeout_minutes to app_settings ============
INSERT INTO app_settings (key, value)
VALUES ('admin_session_timeout_minutes', '1')
ON CONFLICT (key) DO NOTHING;
