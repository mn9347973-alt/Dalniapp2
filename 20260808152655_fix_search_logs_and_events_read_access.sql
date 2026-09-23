-- Allow anon role to read user_medicine_search_logs (admin panel uses anon key with custom auth)
DROP POLICY IF EXISTS "anon_read_search_logs" ON user_medicine_search_logs;
CREATE POLICY "anon_read_search_logs"
  ON user_medicine_search_logs FOR SELECT
  TO anon USING (true);

-- Allow anon role to read pharmacy_events
DROP POLICY IF EXISTS "anon_read_pharmacy_events" ON pharmacy_events;
CREATE POLICY "anon_read_pharmacy_events"
  ON pharmacy_events FOR SELECT
  TO anon USING (true);
