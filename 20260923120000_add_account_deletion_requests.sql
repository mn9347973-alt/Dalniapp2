/*
# Add self-service account deletion requests

1. New Tables
- `account_deletion_requests`
  - `id` (uuid, primary key)
  - `auth_user_id` (uuid, not null) — the requesting user
  - `email` (text, nullable) — snapshot for admin reference
  - `reason` (text, nullable) — optional free-text reason from the user
  - `status` (text, not null, default 'pending') — 'pending' | 'completed' | 'cancelled'
  - `created_at` (timestamptz, default now())
  - `processed_at` (timestamptz, nullable)
  - `processed_by` (uuid, nullable)

2. New RPC Functions
- `request_account_deletion(p_reason text)` — inserts a pending deletion request for the
  calling user (SECURITY DEFINER so it can read auth.uid() safely) and returns the request id.
  Calling it again while a pending request exists just returns the existing request instead
  of creating duplicates.
- `cancel_account_deletion_request()` — lets the user cancel their own pending request.

3. Security
- Enable RLS on account_deletion_requests.
- Users can SELECT only their own requests.
- Only admins can UPDATE (to mark completed/cancelled) via the existing admin role check.
- All writes for regular users go through the SECURITY DEFINER RPCs above, not direct INSERT.

4. Important Notes
- This table only records the *request*. Actually deleting the auth.users row and personal
  data must be done by an admin/back-office job with the Supabase service role key
  (never expose that key in the client). This satisfies Google Play's and Apple's
  requirement that the app itself offer an in-app way to initiate account deletion.
*/

CREATE TABLE IF NOT EXISTS account_deletion_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL,
  email text,
  reason text,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz DEFAULT now(),
  processed_at timestamptz,
  processed_by uuid
);

ALTER TABLE account_deletion_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own deletion requests"
  ON account_deletion_requests FOR SELECT
  TO authenticated
  USING (auth_user_id = auth.uid());

CREATE POLICY "Admins can view all deletion requests"
  ON account_deletion_requests FOR SELECT
  TO authenticated
  USING (get_user_role(auth.uid()) = 'admin');

CREATE POLICY "Admins can update deletion requests"
  ON account_deletion_requests FOR UPDATE
  TO authenticated
  USING (get_user_role(auth.uid()) = 'admin')
  WITH CHECK (get_user_role(auth.uid()) = 'admin');

CREATE OR REPLACE FUNCTION request_account_deletion(p_reason text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing_id uuid;
  v_new_id uuid;
  v_email text;
BEGIN
  SELECT id INTO v_existing_id
  FROM account_deletion_requests
  WHERE auth_user_id = auth.uid() AND status = 'pending'
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();

  INSERT INTO account_deletion_requests (auth_user_id, email, reason)
  VALUES (auth.uid(), v_email, p_reason)
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

CREATE OR REPLACE FUNCTION cancel_account_deletion_request()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE account_deletion_requests
  SET status = 'cancelled', processed_at = now()
  WHERE auth_user_id = auth.uid() AND status = 'pending';
END;
$$;
