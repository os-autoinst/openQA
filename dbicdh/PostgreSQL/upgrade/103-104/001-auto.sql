-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/103/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/104/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules ADD COLUMN always_run integer DEFAULT 0 NOT NULL;

;

COMMIT;

