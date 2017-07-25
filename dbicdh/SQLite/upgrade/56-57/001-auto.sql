-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/56/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/57/001-auto.yml':;

;
BEGIN;

;
<<<<<<< HEAD
ALTER TABLE jobs ADD COLUMN passed_module_count integer NOT NULL DEFAULT 0;

;
ALTER TABLE jobs ADD COLUMN failed_module_count integer NOT NULL DEFAULT 0;

;
ALTER TABLE jobs ADD COLUMN softfailed_module_count integer NOT NULL DEFAULT 0;

;
ALTER TABLE jobs ADD COLUMN skipped_module_count integer NOT NULL DEFAULT 0;
||||||| parent of 317d4804... Disable feature tour by seeting database entry to zero
ALTER TABLE users ADD COLUMN last_login_version text;

;
ALTER TABLE users ADD COLUMN feature_informed boolean NOT NULL DEFAULT 0;
=======
ALTER TABLE users ADD COLUMN feature_version integer NOT NULL DEFAULT 0;
>>>>>>> 317d4804... Disable feature tour by seeting database entry to zero

;

COMMIT;

