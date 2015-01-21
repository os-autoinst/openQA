-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/22/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/23/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules ADD COLUMN soft_failure integer NOT NULL DEFAULT 0;

;
ALTER TABLE job_modules ADD COLUMN milestone integer NOT NULL DEFAULT 0;

;
ALTER TABLE job_modules ADD COLUMN important integer NOT NULL DEFAULT 0;

;
ALTER TABLE job_modules ADD COLUMN fatal integer NOT NULL DEFAULT 0;

;

COMMIT;

