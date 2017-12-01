-- Convert schema '/home/probook/Public/openQA/script/../dbicdh/_source/deploy/59/001-auto.yml' to '/home/probook/Public/openQA/script/../dbicdh/_source/deploy/60/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_groups DROP CONSTRAINT job_groups_name;

;
ALTER TABLE job_groups ADD CONSTRAINT job_groups_name_parent_id UNIQUE (name, parent_id);

;

COMMIT;

