-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/18/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/19/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules DROP CONSTRAINT job_modules_fk_result_id;

;
DROP INDEX job_modules_idx_result_id;

;
ALTER TABLE job_modules ADD COLUMN result character varying DEFAULT 'none' NOT NULL;

;
CREATE INDEX idx_job_modules_result on job_modules (result);

;
ALTER TABLE jobs DROP CONSTRAINT jobs_fk_result_id;

;
ALTER TABLE jobs DROP CONSTRAINT jobs_fk_state_id;

;
DROP INDEX jobs_idx_result_id;

;
DROP INDEX jobs_idx_state_id;

;
ALTER TABLE jobs ADD COLUMN state character varying DEFAULT 'scheduled' NOT NULL;

;
ALTER TABLE jobs ADD COLUMN result character varying DEFAULT 'none' NOT NULL;

;
CREATE INDEX idx_jobs_state on jobs (state);

;
CREATE INDEX idx_jobs_result on jobs (result);

;

COMMIT;

