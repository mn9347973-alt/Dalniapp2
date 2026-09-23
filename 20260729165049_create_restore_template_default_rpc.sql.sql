/*
# Restore Template Default RPC

1. New Functions
- `restore_template_default(p_template_id uuid)`: resets the `body` column of a message_template
  back to its `default_body` value. Used by the admin notification center "restore default" button.

2. Security
- SECURITY DEFINER so the anon-key client can execute it (consistent with other RPCs in this project).
*/

CREATE OR REPLACE FUNCTION public.restore_template_default(p_template_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE message_templates
  SET body = default_body, updated_at = now()
  WHERE id = p_template_id;
END;
$$;
