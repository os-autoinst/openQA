-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/101/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/102/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_group_parents ADD COLUMN default_keep_jobs_in_days integer;

;
ALTER TABLE job_group_parents ADD COLUMN default_keep_important_jobs_in_days integer;

;
ALTER TABLE job_groups ADD COLUMN keep_jobs_in_days integer;

;
ALTER TABLE job_groups ADD COLUMN keep_important_jobs_in_days integer;

;

COMMIT;

