-- Convert schema '/home/okurz/local/os-autoinst/oqa3/script/../dbicdh/_source/deploy/107/001-auto.yml' to '/home/okurz/local/os-autoinst/oqa3/script/../dbicdh/_source/deploy/108/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users ADD COLUMN session_epoch integer NOT NULL DEFAULT 0;

;

COMMIT;

