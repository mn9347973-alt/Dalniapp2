/*
# Admin Plan Selection for Renewals

1. Modified Tables
- `subscription_renewals`: adds two nullable columns:
  - `admin_plan_id` (uuid): the plan the admin chose (may differ from the pharmacy's requested plan)
  - `plan_reason` (text): the admin's reason for choosing that plan

2. Modified Functions
- `approve_subscription_renewal`: now accepts `p_admin_plan_id` (uuid, nullable) and `p_plan_reason` (text, nullable).
  When `p_admin_plan_id` is provided, it overrides the renewal's `plan_id` for duration calculation and
  is stored on the renewal row. The function still implements cumulative balance: if the current
  subscription hasn't expired yet, the new period starts from the current end date, not from now.

3. Security
- No RLS policy changes. Columns are nullable so existing rows are unaffected.
*/

ALTER TABLE subscription_renewals
  ADD COLUMN IF NOT EXISTS admin_plan_id uuid,
  ADD COLUMN IF NOT EXISTS plan_reason text;

CREATE OR REPLACE FUNCTION public.approve_subscription_renewal(
  p_renewal_id uuid,
  p_reviewer text DEFAULT NULL,
  p_admin_plan_id uuid DEFAULT NULL,
  p_plan_reason text DEFAULT NULL
)
RETURNS timestamp with time zone
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  r RECORD;
  effective_plan_id uuid;
  dur int;
  base_ts timestamptz;
  new_end timestamptz;
  is_cumulative boolean;
BEGIN
  SELECT * INTO r FROM subscription_renewals WHERE id = p_renewal_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Renewal not found'; END IF;
  IF r.status = 'approved' THEN RAISE EXCEPTION 'Renewal already approved'; END IF;

  effective_plan_id := COALESCE(p_admin_plan_id, r.plan_id);
  dur := COALESCE(NULLIF((SELECT duration_days FROM subscription_plans WHERE id = effective_plan_id), 0), 30);

  SELECT subscription_ends_at INTO base_ts FROM pharmacies WHERE id = r.pharmacy_id;
  is_cumulative := base_ts IS NOT NULL AND base_ts > now();
  IF is_cumulative THEN
    new_end := base_ts + (dur * interval '1 day');
  ELSE
    new_end := now() + (dur * interval '1 day');
  END IF;

  UPDATE pharmacies
  SET subscription_ends_at = new_end,
    subscription_status = 'active',
    subscription_plan_id = COALESCE(effective_plan_id, subscription_plan_id),
    subscription_started_at = COALESCE(subscription_started_at, now()),
    updated_at = now()
  WHERE id = r.pharmacy_id;

  UPDATE subscription_renewals
  SET status = 'approved',
    reviewed_by = p_reviewer,
    reviewed_at = now(),
    updated_at = now(),
    admin_plan_id = p_admin_plan_id,
    plan_reason = p_plan_reason
  WHERE id = p_renewal_id;

  RETURN new_end;
END;
$function$;
