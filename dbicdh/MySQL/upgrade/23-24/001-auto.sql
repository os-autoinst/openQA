-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/23/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/24/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules ADD COLUMN soft_failure integer NOT NULL DEFAULT 0,
                        ADD COLUMN milestone integer NOT NULL DEFAULT 0,
                        ADD COLUMN important integer NOT NULL DEFAULT 0,
                        ADD COLUMN fatal integer NOT NULL DEFAULT 0;

;
ALTER TABLE jobs DROP COLUMN test_branch,
                 ADD COLUMN backend_info text NULL;

;

COMMIT;

