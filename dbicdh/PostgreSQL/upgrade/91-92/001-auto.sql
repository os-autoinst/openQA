-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/91/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/92/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ALTER COLUMN result_size TYPE bigint;

;

COMMIT;

