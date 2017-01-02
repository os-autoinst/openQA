-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/51/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/52/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP CONSTRAINT jobs_slug;

;
ALTER TABLE jobs DROP COLUMN slug;

;
ALTER TABLE machines DROP COLUMN variables;

;
ALTER TABLE machines ADD COLUMN description text;

;
ALTER TABLE products DROP COLUMN variables;

;
ALTER TABLE products ADD COLUMN description text;

;
ALTER TABLE test_suites DROP COLUMN variables;

;
ALTER TABLE test_suites ADD COLUMN description text;

;

COMMIT;
