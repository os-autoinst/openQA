-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/48/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/49/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN logs_present boolean NOT NULL DEFAULT 1;

;

COMMIT;

