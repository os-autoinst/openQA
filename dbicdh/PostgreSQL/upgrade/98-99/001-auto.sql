-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/98/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/99/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP COLUMN backend_info;

;

COMMIT;

