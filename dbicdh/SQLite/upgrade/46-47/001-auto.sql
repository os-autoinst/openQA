-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/46/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/47/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_group_parents (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  default_size_limit_gb integer,
  default_keep_logs_in_days integer,
  default_keep_important_logs_in_days integer,
  default_keep_results_in_days integer,
  default_keep_important_results_in_days integer,
  default_priority integer,
  sort_order integer,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX job_group_parents_name ON job_group_parents (name);

;
CREATE TEMPORARY TABLE job_groups_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  parent_id integer,
  size_limit_gb integer,
  keep_logs_in_days integer,
  keep_important_logs_in_days integer,
  keep_results_in_days integer,
  keep_important_results_in_days integer,
  default_priority integer,
  sort_order integer,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (parent_id) REFERENCES job_group_parents(id) ON DELETE SET NULL ON UPDATE CASCADE
);

;
INSERT INTO job_groups_temp_alter( id, name, size_limit_gb, keep_logs_in_days, t_created, t_updated) SELECT id, name, size_limit_gb, keep_logs_in_days, t_created, t_updated FROM job_groups;

;
DROP TABLE job_groups;

;
CREATE TABLE job_groups (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  parent_id integer,
  size_limit_gb integer,
  keep_logs_in_days integer,
  keep_important_logs_in_days integer,
  keep_results_in_days integer,
  keep_important_results_in_days integer,
  default_priority integer,
  sort_order integer,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (parent_id) REFERENCES job_group_parents(id) ON DELETE SET NULL ON UPDATE CASCADE
);

;
CREATE INDEX job_groups_idx_parent_id02 ON job_groups (parent_id);

;
CREATE UNIQUE INDEX job_groups_name02 ON job_groups (name);

;
INSERT INTO job_groups SELECT id, name, parent_id, size_limit_gb, keep_logs_in_days, keep_important_logs_in_days, keep_results_in_days, keep_important_results_in_days, default_priority, sort_order, description, t_created, t_updated FROM job_groups_temp_alter;

;
DROP TABLE job_groups_temp_alter;

;

COMMIT;

