-- Admin activity logs table
CREATE TABLE IF NOT EXISTS admin_activity_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  admin_email text NOT NULL,
  action text NOT NULL,
  details text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Index for sorting and filtering
CREATE INDEX idx_admin_activity_logs_admin_id ON admin_activity_logs(admin_user_id);
CREATE INDEX idx_admin_activity_logs_created_at ON admin_activity_logs(created_at DESC);

-- Enable RLS
ALTER TABLE admin_activity_logs ENABLE ROW LEVEL SECURITY;

-- Only authenticated admins can read logs
CREATE POLICY "select_admin_activity_logs"
  ON admin_activity_logs FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM admin_users au
      WHERE au.user_id = auth.uid() AND au.is_active
    )
  );

-- Only authenticated admins can insert logs
CREATE POLICY "insert_admin_activity_logs"
  ON admin_activity_logs FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM admin_users au
      WHERE au.user_id = auth.uid() AND au.is_active
    )
  );

-- RPC: log an admin action
CREATE OR REPLACE FUNCTION log_admin_action(
  p_action text,
  p_details text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin admin_users%ROWTYPE;
BEGIN
  SELECT * INTO v_admin FROM admin_users WHERE user_id = auth.uid() AND is_active LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Admin not found or inactive';
  END IF;

  INSERT INTO admin_activity_logs (admin_user_id, admin_email, action, details)
  VALUES (v_admin.id, v_admin.email, p_action, p_details);
END;
$$;

-- RPC: get admin activity logs with optional filtering
CREATE OR REPLACE FUNCTION get_admin_activity_logs(
  p_admin_user_id uuid DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL,
  p_limit int DEFAULT 100
) RETURNS TABLE (
  id uuid,
  admin_user_id uuid,
  admin_email text,
  action text,
  details text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    l.id,
    l.admin_user_id,
    l.admin_email,
    l.action,
    l.details,
    l.created_at
  FROM admin_activity_logs l
  WHERE (p_admin_user_id IS NULL OR l.admin_user_id = p_admin_user_id)
    AND (p_date_from IS NULL OR l.created_at >= p_date_from)
    AND (p_date_to IS NULL OR l.created_at <= p_date_to)
  ORDER BY l.created_at DESC
  LIMIT p_limit;
END;
$$;

-- Grant execute to authenticated
GRANT EXECUTE ON FUNCTION log_admin_action TO authenticated;
GRANT EXECUTE ON FUNCTION get_admin_activity_logs TO authenticated;