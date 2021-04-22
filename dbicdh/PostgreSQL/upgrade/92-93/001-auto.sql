-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/92/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/93/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN archived boolean DEFAULT '0' NOT NULL;

;

COMMIT;

