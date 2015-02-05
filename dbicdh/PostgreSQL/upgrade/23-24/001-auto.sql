-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/22/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/23/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules ADD COLUMN soft_failure integer DEFAULT 0 NOT NULL;

;
ALTER TABLE job_modules ADD COLUMN milestone integer DEFAULT 0 NOT NULL;

;
ALTER TABLE job_modules ADD COLUMN important integer DEFAULT 0 NOT NULL;

;
ALTER TABLE job_modules ADD COLUMN fatal integer DEFAULT 0 NOT NULL;

;

COMMIT;

