-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/88/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/89/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP COLUMN backend;

;

COMMIT;

