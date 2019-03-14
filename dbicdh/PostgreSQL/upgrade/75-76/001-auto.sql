-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/75/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/76/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_group_parents ADD COLUMN carry_over_bugrefs boolean;

;
ALTER TABLE job_groups ADD COLUMN carry_over_bugrefs boolean;

;

COMMIT;

