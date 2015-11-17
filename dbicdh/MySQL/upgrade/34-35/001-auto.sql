-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/34/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/35/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE needles ADD COLUMN file_present enum('0','1') NOT NULL DEFAULT '1';

;

COMMIT;

