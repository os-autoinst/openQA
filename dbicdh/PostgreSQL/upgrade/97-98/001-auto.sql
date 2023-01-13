-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/97/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/98/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_locks ALTER COLUMN owner TYPE bigint;

;

COMMIT;

