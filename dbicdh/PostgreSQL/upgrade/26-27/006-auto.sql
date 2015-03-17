-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/28/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates ALTER COLUMN group_id SET NOT NULL;

;

COMMIT;

