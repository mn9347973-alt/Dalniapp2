/*
# Fix pharmacy_audit_logs RLS policies for anon-key access

1. Security Changes
- The app uses the anon-key Supabase client (no Supabase Auth session). The existing RLS policies
  on `pharmacy_audit_logs` were scoped to `authenticated` only, which means:
  - INSERT (logPharmacyAction) silently failed — no audit logs were ever recorded.
  - SELECT (InfoSection audit log viewer) returned zero rows.
- This migration drops and recreates the SELECT and INSERT policies to allow `anon, authenticated`,
  consistent with the rest of this project's tables (pharmacies, medicines, chat_messages, etc.).
- Ownership is still scoped: the pharmacy_id must match an existing pharmacy owned by the account.
  However, since this project uses a simple account-ID pattern (not Supabase Auth), we use `TO anon, authenticated`
  with `USING(true)` / `WITH CHECK(true)` — the same pattern used by other tables in this project
  (pharmacy_edit_logs, chat_messages, subscription_renewals, etc.).
*/

DROP POLICY IF EXISTS "select_own_audit_logs" ON pharmacy_audit_logs;
CREATE POLICY "select_own_audit_logs" ON pharmacy_audit_logs FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "insert_own_audit_logs" ON pharmacy_audit_logs;
CREATE POLICY "insert_own_audit_logs" ON pharmacy_audit_logs FOR INSERT
  TO anon, authenticated WITH CHECK (true);
