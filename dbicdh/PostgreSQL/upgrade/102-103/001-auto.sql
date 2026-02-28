--
-- Upgrade from 102 to 103
--
-- Add deleted_at column to users table for GDPR compliance (user data deletion)
--
ALTER TABLE users ADD COLUMN deleted_at timestamp;
CREATE INDEX users_idx_deleted_at ON users (deleted_at);
