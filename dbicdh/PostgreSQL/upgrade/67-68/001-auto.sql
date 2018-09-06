-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/67/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/68/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates ALTER COLUMN prio DROP NOT NULL;

;

COMMIT;

