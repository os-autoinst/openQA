-- Convert schema '/home/adamw/local/openQA/script/../dbicdh/_source/deploy/97/001-auto.yml' to '/home/adamw/local/openQA/script/../dbicdh/_source/deploy/98/001-auto.yml':;

;
BEGIN;

;
DROP INDEX idx_value_settings;

;
DROP INDEX idx_job_id_value_settings;

;
CREATE INDEX idx_value_settings on job_settings (key, value) WHERE key IN ('DISTRI', 'VERSION', 'FLAVOR', 'ARCH', 'BUILD', 'ISO', 'HDD_1', 'WORKER_CLASS');

;
CREATE INDEX idx_job_id_value_settings on job_settings (job_id, key, value) WHERE key IN ('DISTRI', 'VERSION', 'FLAVOR', 'ARCH', 'BUILD', 'ISO', 'HDD_1', 'WORKER_CLASS');

;

COMMIT;

