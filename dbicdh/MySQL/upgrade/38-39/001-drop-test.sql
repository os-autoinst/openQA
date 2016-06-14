-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/39/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/40/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP COLUMN test;

;

COMMIT;

