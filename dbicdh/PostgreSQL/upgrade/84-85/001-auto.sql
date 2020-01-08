-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/84/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/85/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_group_parents ADD COLUMN exclusively_kept_asset_size bigint;

;

COMMIT;

