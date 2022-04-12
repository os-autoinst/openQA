-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/93/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/94/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules ALTER COLUMN id TYPE bigint;

;
ALTER TABLE needles ALTER COLUMN last_seen_module_id TYPE bigint;

;
ALTER TABLE needles ALTER COLUMN last_matched_module_id TYPE bigint;

;

COMMIT;

