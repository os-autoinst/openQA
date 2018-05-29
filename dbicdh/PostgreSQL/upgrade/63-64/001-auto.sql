-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/63/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/64/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP COLUMN retry_avbl;

;

COMMIT;

