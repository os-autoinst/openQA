-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/29/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/30/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE gru_tasks (
  id INTEGER PRIMARY KEY NOT NULL,
  taskname text NOT NULL,
  args text NOT NULL,
  run_at datetime NOT NULL,
  priority integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
ALTER TABLE assets ADD COLUMN size bigint;

;
ALTER TABLE job_groups ADD COLUMN size_limit_gb integer NOT NULL DEFAULT 100;

;
ALTER TABLE job_groups ADD COLUMN keep_logs_in_days integer NOT NULL DEFAULT 14;

;
ALTER TABLE jobs_assets ADD COLUMN created_by boolean NOT NULL DEFAULT 0;

;

COMMIT;

