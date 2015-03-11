-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/26/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE job_groups (
  id integer NOT NULL auto_increment,
  name text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  UNIQUE job_groups_name (name)
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;
ALTER TABLE jobs ADD COLUMN group_id integer NULL,
                 ADD INDEX jobs_idx_group_id (group_id),
                 ADD CONSTRAINT jobs_fk_group_id FOREIGN KEY (group_id) REFERENCES job_groups (id) ON DELETE SET NULL ON UPDATE CASCADE;

;

COMMIT;

