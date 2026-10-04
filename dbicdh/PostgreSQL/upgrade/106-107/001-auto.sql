-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/106/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/107/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE api_keys ADD COLUMN comment text;

;

COMMIT;

