-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/50/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/51/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN assigned_worker_id integer;

;
CREATE INDEX jobs_idx_assigned_worker_id on jobs (assigned_worker_id);

;
ALTER TABLE jobs ADD CONSTRAINT jobs_fk_assigned_worker_id FOREIGN KEY (assigned_worker_id)
  REFERENCES workers (id) ON DELETE SET NULL DEFERRABLE;

;

COMMIT;

