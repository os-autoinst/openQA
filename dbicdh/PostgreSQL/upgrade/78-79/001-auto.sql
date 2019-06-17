-- Convert schema '/home/kalikiana/dev/openQA/repos/openQA/script/../dbicdh/_source/deploy/78/001-auto.yml' to '/home/kalikiana/dev/openQA/repos/openQA/script/../dbicdh/_source/deploy/79/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_groups ADD COLUMN template text;

;

COMMIT;

