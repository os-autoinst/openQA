-- Convert schema '/home/lukas/Code/openQA/script/../dbicdh/_source/deploy/57/001-auto.yml' to '/home/lukas/Code/openQA/script/../dbicdh/_source/deploy/58/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users ADD COLUMN feature_version integer NOT NULL DEFAULT 0;

;

COMMIT;

