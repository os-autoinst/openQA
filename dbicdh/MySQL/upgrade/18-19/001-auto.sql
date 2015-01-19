-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/18/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/19/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules DROP FOREIGN KEY job_modules_fk_result_id,
                        DROP INDEX job_modules_idx_result_id,
                        ADD COLUMN result varchar(255) NOT NULL DEFAULT 'none',
                        ADD INDEX idx_job_modules_result (result);

;
ALTER TABLE job_results;

;
ALTER TABLE job_states;

;
ALTER TABLE jobs DROP FOREIGN KEY jobs_fk_result_id,
                 DROP FOREIGN KEY jobs_fk_state_id,
                 DROP INDEX jobs_idx_result_id,
                 DROP INDEX jobs_idx_state_id,
                 ADD COLUMN state varchar(255) NOT NULL DEFAULT 'scheduled',
                 ADD COLUMN result varchar(255) NOT NULL DEFAULT 'none',
                 ADD INDEX idx_jobs_state (state),
                 ADD INDEX idx_jobs_result (result);

;

COMMIT;

