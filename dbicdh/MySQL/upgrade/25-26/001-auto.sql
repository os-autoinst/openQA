-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/25/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/26/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN result_dir text NULL,
                 ADD COLUMN backend varchar(255) NULL;

;

COMMIT;

