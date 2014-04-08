-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/4/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/5/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN clone_id integer;

;
CREATE INDEX jobs_idx_clone_id02 ON jobs (clone_id);

;

COMMIT;

