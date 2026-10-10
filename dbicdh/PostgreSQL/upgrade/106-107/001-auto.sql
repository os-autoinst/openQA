-- Convert schema '/home/okurz/local/os-autoinst/oqa3/script/../dbicdh/_source/deploy/106/001-auto.yml' to '/home/okurz/local/os-autoinst/oqa3/script/../dbicdh/_source/deploy/107/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users ADD COLUMN password text;

;

COMMIT;

