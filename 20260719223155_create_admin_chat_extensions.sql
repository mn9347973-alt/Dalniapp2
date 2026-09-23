/*
# Dulni Admin Pharmacy Chat + Notifications Extensions

## Overview
Extends the existing chat and notification tables to support the admin-side "الدردشة مع الصيدليات"
section: attachments (images/files) on messages, conversation archiving, an admin-send function
that bypasses the pharmacy 5/day limit, and a read-receipt marker for admin messages.

## Context
Dulni uses custom client-side auth (no Supabase Auth). Admin = account id `776695102`. All RLS
policies use `TO anon, authenticated` (frontend enforces context). Consistent with existing tables.

## Changes

### 1. chat_messages — add attachment columns (idempotent)
- `attachment_path` text — storage path for an attached image/file (nullable)
- `attachment_name` text — original file name for display (nullable)
- `delivered_at` timestamptz — when the message was delivered to the recipient (nullable)
Existing rows keep NULL for these columns (text/timestamptz are nullable, no data loss).

### 2. chat_archives — NEW table
Stores archived conversation summaries so admins can archive a pharmacy chat while preserving
the full message history in chat_messages.
- id, pharmacy_id (FK pharmacies ON DELETE CASCADE), archived_by (account id), reason,
  archived_at (defaults now), created_at
- Unique (pharmacy_id) — one archive record per pharmacy (re-archive updates timestamp/reason)

### 3. pharmacy_notifications — already exists
Confirmed present. Used to send notifications to pharmacies (renewal reminders, approval/rejection
notices). No schema change needed here; the frontend already inserts rows.

### 4. send_admin_chat_message function
Inserts a chat_messages row with sender='admin'. Admin messages are NOT subject to the pharmacy
5/day limit (that limit applies only to pharmacy-initiated messages via send_pharmacy_message).
Sets delivered_at = now() (admin→pharmacy is considered delivered on insert). Returns the row id.

### 5. mark_chat_read function
Marks all unread messages in a conversation as read for a given recipient role. Used by both
admin (marking pharmacy messages read when admin opens the chat) and pharmacy (marking admin
messages read). Sets read_at = now().

## Security (RLS)
- chat_messages: already has SELECT/INSERT/UPDATE policies (TO anon, authenticated). The new
  columns are covered by the existing UPDATE policy (it uses USING/WITH CHECK true).
- chat_archives: NEW table — RLS enabled, TO anon, authenticated CRUD (single-tenant trust model).
- pharmacy_notifications: already has policies.

## Notes
1. Idempotent: DO $$ ... END $$ for conditional column adds; DROP IF EXISTS before CREATE POLICY
   and before CREATE OR REPLACE FUNCTION (functions use OR REPLACE so safe).
2. No data loss — only nullable column additions and a new table.
3. The admin chat UI uses send_admin_chat_message; the pharmacy chat UI (already built) continues
   to use send_pharmacy_message with the 5/day limit.
*/

-- ============ chat_messages: add attachment + delivery columns ============
DO $$
DECLARE
  has_attachment_path boolean;
  has_attachment_name boolean;
  has_delivered_at boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'chat_messages' AND column_name = 'attachment_path'
  ) INTO has_attachment_path;
  IF NOT has_attachment_path THEN
    ALTER TABLE chat_messages ADD COLUMN attachment_path text;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'chat_messages' AND column_name = 'attachment_name'
  ) INTO has_attachment_name;
  IF NOT has_attachment_name THEN
    ALTER TABLE chat_messages ADD COLUMN attachment_name text;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'chat_messages' AND column_name = 'delivered_at'
  ) INTO has_delivered_at;
  IF NOT has_delivered_at THEN
    ALTER TABLE chat_messages ADD COLUMN delivered_at timestamptz;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS chat_messages_pharmacy_created_idx
  ON chat_messages(pharmacy_id, created_at);

-- ============ chat_archives ============
CREATE TABLE IF NOT EXISTS chat_archives (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
  archived_by text,
  reason text,
  archived_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS chat_archives_pharmacy_key
  ON chat_archives(pharmacy_id);

ALTER TABLE chat_archives ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "chat_archives_select_all" ON chat_archives;
CREATE POLICY "chat_archives_select_all" ON chat_archives FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "chat_archives_insert_all" ON chat_archives;
CREATE POLICY "chat_archives_insert_all" ON chat_archives FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "chat_archives_update_all" ON chat_archives;
CREATE POLICY "chat_archives_update_all" ON chat_archives FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "chat_archives_delete_all" ON chat_archives;
CREATE POLICY "chat_archives_delete_all" ON chat_archives FOR DELETE
  TO anon, authenticated USING (true);

-- ============ send_admin_chat_message ============
CREATE OR REPLACE FUNCTION send_admin_chat_message(
  p_pharmacy_id uuid,
  p_body text,
  p_attachment_path text DEFAULT NULL,
  p_attachment_name text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  msg_id uuid;
BEGIN
  IF trim(coalesce(p_body, '')) = '' AND p_attachment_path IS NULL THEN
    RAISE EXCEPTION 'Body or attachment required';
  END IF;

  INSERT INTO chat_messages (pharmacy_id, sender, body, attachment_path, attachment_name, delivered_at)
    VALUES (p_pharmacy_id, 'admin', coalesce(p_body, ''), p_attachment_path, p_attachment_name, now())
    RETURNING id INTO msg_id;

  RETURN msg_id;
END;
$$ LANGUAGE plpgsql;

-- ============ mark_chat_read ============
CREATE OR REPLACE FUNCTION mark_chat_read(p_pharmacy_id uuid, p_recipient text)
RETURNS void AS $$
BEGIN
  -- recipient='admin' => mark pharmacy messages as read by admin
  -- recipient='pharmacy' => mark admin messages as read by pharmacy
  IF p_recipient = 'admin' THEN
    UPDATE chat_messages SET read_at = now()
      WHERE pharmacy_id = p_pharmacy_id AND sender = 'pharmacy' AND read_at IS NULL;
  ELSIF p_recipient = 'pharmacy' THEN
    UPDATE chat_messages SET read_at = now()
      WHERE pharmacy_id = p_pharmacy_id AND sender = 'admin' AND read_at IS NULL;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- ============ archive_chat_conversation ============
CREATE OR REPLACE FUNCTION archive_chat_conversation(p_pharmacy_id uuid, p_archived_by text, p_reason text DEFAULT NULL)
RETURNS uuid AS $$
DECLARE
  arc_id uuid;
BEGIN
  INSERT INTO chat_archives (pharmacy_id, archived_by, reason)
    VALUES (p_pharmacy_id, p_archived_by, p_reason)
    ON CONFLICT (pharmacy_id) DO UPDATE
      SET archived_by = EXCLUDED.archived_by,
          reason = EXCLUDED.reason,
          archived_at = now()
    RETURNING id INTO arc_id;
  RETURN arc_id;
END;
$$ LANGUAGE plpgsql;

-- ============ unarchive_chat_conversation ============
CREATE OR REPLACE FUNCTION unarchive_chat_conversation(p_pharmacy_id uuid)
RETURNS void AS $$
BEGIN
  DELETE FROM chat_archives WHERE pharmacy_id = p_pharmacy_id;
END;
$$ LANGUAGE plpgsql;
