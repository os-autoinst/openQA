-- Convert schema '/home/openQA/openQA/script/../dbicdh/_source/deploy/36/001-auto.yml' to '/home/openQA/openQA/script/../dbicdh/_source/deploy/37/001-auto.yml':;

;
BEGIN;

;
CREATE INDEX idx_value_settings on job_settings (key, value);

;
CREATE INDEX idx_job_value_settings on job_settings (id, key, value);

;

COMMIT;

