-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/19/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/20/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules DROP COLUMN result_id;

;
ALTER TABLE jobs DROP COLUMN state_id;

;
ALTER TABLE jobs DROP COLUMN result_id;

;
DROP TABLE job_results CASCADE;

;
DROP TABLE job_states CASCADE;

;

COMMIT;

