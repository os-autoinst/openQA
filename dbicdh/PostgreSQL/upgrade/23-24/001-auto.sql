-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/23/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/24/001-auto.yml':;

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
ALTER TABLE jobs DROP COLUMN test_branch;

;
ALTER TABLE jobs ADD COLUMN backend_info text;

;

COMMIT;

