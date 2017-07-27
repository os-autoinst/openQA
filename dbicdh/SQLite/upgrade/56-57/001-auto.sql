-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/56/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/57/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN passed_module_count integer NOT NULL DEFAULT 0;

;
ALTER TABLE jobs ADD COLUMN failed_module_count integer NOT NULL DEFAULT 0;

;
ALTER TABLE jobs ADD COLUMN softfailed_module_count integer NOT NULL DEFAULT 0;

;
ALTER TABLE jobs ADD COLUMN skipped_module_count integer NOT NULL DEFAULT 0;

;

COMMIT;

