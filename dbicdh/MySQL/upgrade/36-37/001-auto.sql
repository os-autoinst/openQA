-- Convert schema '/home/openQA/openQA/script/../dbicdh/_source/deploy/36/001-auto.yml' to '/home/openQA/openQA/script/../dbicdh/_source/deploy/37/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_settings ADD INDEX idx_value_settings (key, value),
                         ADD INDEX idx_job_value_settings (id, key, value);

;

COMMIT;

