-- Convert schema '/home/okurz/local/os-autoinst/oqa4/script/../dbicdh/_source/deploy/107/001-auto.yml' to '/home/okurz/local/os-autoinst/oqa4/script/../dbicdh/_source/deploy/108/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE api_keys ADD COLUMN is_operator integer DEFAULT 1 NOT NULL;

;
ALTER TABLE api_keys ADD COLUMN is_admin integer DEFAULT 1 NOT NULL;

;

COMMIT;

