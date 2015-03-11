-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/28/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates CHANGE COLUMN prio prio integer NOT NULL;

;
ALTER TABLE test_suites DROP COLUMN prio;

;

COMMIT;

