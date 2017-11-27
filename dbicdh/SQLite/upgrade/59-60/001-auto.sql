-- Convert schema '/home/probook/Public/openQA/script/../dbicdh/_source/deploy/59/001-auto.yml' to '/home/probook/Public/openQA/script/../dbicdh/_source/deploy/60/001-auto.yml':;

;
BEGIN;

;
DROP INDEX job_groups_name;

;
CREATE UNIQUE INDEX job_groups_name_parent_id ON job_groups (name, parent_id);

;

COMMIT;

