-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/85/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/86/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_group_parents DROP COLUMN default_size_limit_gb;

;
ALTER TABLE job_group_parents ADD COLUMN size_limit_gb integer;

;

COMMIT;

