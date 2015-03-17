-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/26/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_groups (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX job_groups_name ON job_groups (name);

;
ALTER TABLE jobs ADD COLUMN group_id integer;

;
CREATE INDEX jobs_idx_group_id ON jobs (group_id);

;

;

COMMIT;

