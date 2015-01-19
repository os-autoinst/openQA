-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/18/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/19/001-auto.yml':;

;
BEGIN;

;
DROP INDEX job_modules_idx_result_id;

;
ALTER TABLE job_modules ADD COLUMN result varchar NOT NULL DEFAULT 'none';

;
CREATE INDEX idx_job_modules_result ON job_modules (result);

;
DROP INDEX jobs_idx_result_id;

;
DROP INDEX jobs_idx_state_id;

;
ALTER TABLE jobs ADD COLUMN state varchar NOT NULL DEFAULT 'scheduled';

;
ALTER TABLE jobs ADD COLUMN result varchar NOT NULL DEFAULT 'none';

;
CREATE INDEX idx_jobs_state ON jobs (state);

;
CREATE INDEX idx_jobs_result ON jobs (result);

;

COMMIT;

