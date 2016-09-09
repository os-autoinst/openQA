-- Convert schema '/home/openQA/openQA/script/../dbicdh/_source/deploy/43/001-auto.yml' to '/home/openQA/openQA/script/../dbicdh/_source/deploy/44/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE assets ADD COLUMN checksum text;

;
ALTER TABLE comments DROP COLUMN hidden;

;
ALTER TABLE comments ADD COLUMN flags integer DEFAULT 0;

;
ALTER TABLE job_locks DROP CONSTRAINT job_locks_fk_locked_by;

;
DROP INDEX job_locks_idx_locked_by;

;
ALTER TABLE job_locks ADD COLUMN count integer DEFAULT 1 NOT NULL;

;
ALTER TABLE job_locks ALTER COLUMN locked_by TYPE text;

;

COMMIT;

