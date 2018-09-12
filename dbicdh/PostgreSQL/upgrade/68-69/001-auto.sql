-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/68/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/69/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE workers ADD COLUMN upload_progress jsonb;

;

COMMIT;

