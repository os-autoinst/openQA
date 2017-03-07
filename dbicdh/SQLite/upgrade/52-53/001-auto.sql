-- Convert schema '/home/adamw/local/openQA/script/../dbicdh/_source/deploy/52/001-auto.yml' to '/home/adamw/local/openQA/script/../dbicdh/_source/deploy/53/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_groups ADD COLUMN build_version_sort boolean NOT NULL DEFAULT 1;

;

COMMIT;

