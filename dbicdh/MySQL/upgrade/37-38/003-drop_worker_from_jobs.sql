-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/37/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/38/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_settings DROP INDEX idx_job_value_settings,
                         ADD INDEX idx_job_id_value_settings (job_id, key, value);

;
ALTER TABLE jobs DROP FOREIGN KEY jobs_fk_worker_id,
                 DROP INDEX jobs_idx_worker_id,
                 DROP COLUMN worker_id;

;

COMMIT;

