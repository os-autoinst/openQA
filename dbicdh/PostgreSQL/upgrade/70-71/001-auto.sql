-- Convert schema '/home/riafarov/repos/openQA/script/../dbicdh/_source/deploy/70/001-auto.yml' to '/home/riafarov/repos/openQA/script/../dbicdh/_source/deploy/71/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules ADD COLUMN always_rollback integer DEFAULT 0 NOT NULL;

;

COMMIT;

