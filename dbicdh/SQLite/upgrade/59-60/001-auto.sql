-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/59/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/60/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE assets ADD COLUMN last_use_job_id integer;

;
CREATE INDEX assets_idx_last_use_job_id ON assets (last_use_job_id);

;

;

COMMIT;

