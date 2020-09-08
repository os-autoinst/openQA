-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/89/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/90/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE workers ADD COLUMN t_seen timestamp;

;

COMMIT;

