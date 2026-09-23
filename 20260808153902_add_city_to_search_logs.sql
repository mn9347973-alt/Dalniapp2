-- Add city column to user_medicine_search_logs for city-level filtering in reports
ALTER TABLE user_medicine_search_logs ADD COLUMN IF NOT EXISTS city text;
