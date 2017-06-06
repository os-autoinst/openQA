-- Convert schema '/home/ettore/_git/openQA/script/../dbicdh/_source/deploy/55/001-auto.yml' to '/home/ettore/_git/openQA/script/../dbicdh/_source/deploy/56/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_group_parents ADD COLUMN build_version_sort boolean DEFAULT '1' NOT NULL;

;

COMMIT;

