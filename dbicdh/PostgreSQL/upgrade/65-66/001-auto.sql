-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/65/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/66/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN blocked_by_id integer;

;
CREATE INDEX jobs_idx_blocked_by_id on jobs (blocked_by_id);

;
ALTER TABLE jobs ADD CONSTRAINT jobs_fk_blocked_by_id FOREIGN KEY (blocked_by_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

