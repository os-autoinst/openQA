-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/71/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/72/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE workers ADD COLUMN error text;

;

COMMIT;

