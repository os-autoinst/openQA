-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/38/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/39/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN TEST text;

;
ALTER TABLE jobs ADD COLUMN DISTRI text;

;
ALTER TABLE jobs ADD COLUMN VERSION text;

;
ALTER TABLE jobs ADD COLUMN FLAVOR text;

;
ALTER TABLE jobs ADD COLUMN ARCH text;

;
ALTER TABLE jobs ADD COLUMN BUILD text;

;
ALTER TABLE jobs ADD COLUMN MACHINE text;

;

COMMIT;

