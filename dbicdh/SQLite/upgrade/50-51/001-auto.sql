-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/50/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/51/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN assigned_worker_id integer;

;
CREATE INDEX jobs_idx_assigned_worker_id ON jobs (assigned_worker_id);

;

;

COMMIT;

