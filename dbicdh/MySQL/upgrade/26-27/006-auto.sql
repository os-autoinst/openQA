-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/28/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates CHANGE COLUMN group_id group_id integer NOT NULL;

;

COMMIT;

