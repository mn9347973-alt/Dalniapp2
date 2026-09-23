/*
# Prevent duplicate medicines in approved and banned lists

## Summary
1. Removes duplicate entries from approved_medicines and banned_medicines,
   keeping only the oldest entry (by created_at) for each duplicate group.
   Duplicates are identified by matching (lower(trade_name), lower(trade_name_en)).
2. Adds unique indexes to prevent future duplicates.

## Data cleanup
- approved_medicines: deletes duplicate rows, keeps oldest per (trade_name, trade_name_en)
- banned_medicines: deletes duplicate rows, keeps oldest per (trade_name, trade_name_en)

## Indexes added
- approved_medicines_unique_trade: UNIQUE on (COALESCE(lower(trade_name),''), COALESCE(lower(trade_name_en),''))
- banned_medicines_unique_trade: UNIQUE on (COALESCE(lower(trade_name),''), COALESCE(lower(trade_name_en),''))

## Security
No RLS changes.
*/

-- ============ 1. Deduplicate approved_medicines ============
DELETE FROM approved_medicines a1
USING approved_medicines a2
WHERE a1.id > a2.id
  AND COALESCE(lower(a1.trade_name), '') = COALESCE(lower(a2.trade_name), '')
  AND COALESCE(lower(a1.trade_name_en), '') = COALESCE(lower(a2.trade_name_en), '');

-- ============ 2. Deduplicate banned_medicines ============
DELETE FROM banned_medicines b1
USING banned_medicines b2
WHERE b1.id > b2.id
  AND COALESCE(lower(b1.trade_name), '') = COALESCE(lower(b2.trade_name), '')
  AND COALESCE(lower(b1.trade_name_en), '') = COALESCE(lower(b2.trade_name_en), '');

-- ============ 3. Create unique indexes ============
DROP INDEX IF EXISTS approved_medicines_unique_trade;
DROP INDEX IF EXISTS banned_medicines_unique_trade;

CREATE UNIQUE INDEX approved_medicines_unique_trade
  ON approved_medicines USING btree (
    COALESCE(lower(trade_name), ''),
    COALESCE(lower(trade_name_en), '')
  );

CREATE UNIQUE INDEX banned_medicines_unique_trade
  ON banned_medicines USING btree (
    COALESCE(lower(trade_name), ''),
    COALESCE(lower(trade_name_en), '')
  );
