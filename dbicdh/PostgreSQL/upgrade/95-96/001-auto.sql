-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/95/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/96/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE worker_properties ALTER COLUMN id TYPE bigint;

;
ALTER TABLE worker_properties ALTER COLUMN worker_id TYPE bigint;

;
ALTER TABLE workers ALTER COLUMN id TYPE bigint;

;

COMMIT;

