-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/38/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/39/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN TEST text NULL,
                 ADD COLUMN DISTRI text NULL,
                 ADD COLUMN VERSION text NULL,
                 ADD COLUMN FLAVOR text NULL,
                 ADD COLUMN ARCH text NULL,
                 ADD COLUMN BUILD text NULL,
                 ADD COLUMN MACHINE text NULL;

;

COMMIT;

