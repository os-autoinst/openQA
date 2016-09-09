-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/40/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/41/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules DROP COLUMN soft_failure;

;

COMMIT;

