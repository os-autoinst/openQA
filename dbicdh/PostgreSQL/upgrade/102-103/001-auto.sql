--
-- Upgrade from 102 to 103
--
-- Add deleted_at column to users table for GDPR compliance (user data deletion)
-- Allow NULL for user_id in comments table for anonymization support
--
ALTER TABLE users ADD COLUMN deleted_at timestamp;
CREATE INDEX users_idx_deleted_at ON users (deleted_at);
ALTER TABLE comments ALTER COLUMN user_id DROP NOT NULL;
