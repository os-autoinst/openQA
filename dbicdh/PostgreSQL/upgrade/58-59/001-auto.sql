-- Convert schema '/home/lukas/Code/openQA/script/../dbicdh/_source/deploy/58/001-auto.yml' to '/home/lukas/Code/openQA/script/../dbicdh/_source/deploy/59/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users ALTER COLUMN feature_version SET DEFAULT 1;

;

COMMIT;

