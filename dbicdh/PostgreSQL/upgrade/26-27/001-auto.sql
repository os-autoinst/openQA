-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/26/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_groups (
  id serial NOT NULL,
  name text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT job_groups_name UNIQUE (name)
);

;
ALTER TABLE jobs ADD COLUMN group_id integer;

;
CREATE INDEX jobs_idx_group_id on jobs (group_id);

;
ALTER TABLE jobs ADD CONSTRAINT jobs_fk_group_id FOREIGN KEY (group_id)
  REFERENCES job_groups (id) ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

