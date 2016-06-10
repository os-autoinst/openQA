BEGIN;

DROP INDEX idx_job_value_settings;

;
CREATE INDEX idx_job_id_value_settings on job_settings (job_id, key, value);

;
ALTER TABLE jobs DROP CONSTRAINT jobs_fk_worker_id;

;
DROP INDEX jobs_idx_worker_id;

;
ALTER TABLE jobs DROP COLUMN worker_id;

COMMIT;
