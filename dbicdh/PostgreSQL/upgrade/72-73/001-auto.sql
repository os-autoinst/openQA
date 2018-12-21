-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/72/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/73/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE needles ADD COLUMN last_updated timestamp;

;

COMMIT;

