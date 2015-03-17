-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/28/001-auto.yml':;

;
BEGIN;

;
CREATE TEMPORARY TABLE job_templates_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  machine_id integer NOT NULL,
  test_suite_id integer NOT NULL,
  prio integer NOT NULL,
  group_id integer,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id),
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO job_templates_temp_alter( id, product_id, machine_id, test_suite_id, prio, group_id, t_created, t_updated) SELECT id, product_id, machine_id, test_suite_id, prio, group_id, t_created, t_updated FROM job_templates;

;
DROP TABLE job_templates;

;
CREATE TABLE job_templates (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  machine_id integer NOT NULL,
  test_suite_id integer NOT NULL,
  prio integer NOT NULL,
  group_id integer,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id),
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_templates_idx_group_id02 ON job_templates (group_id);

;
CREATE INDEX job_templates_idx_machine_id02 ON job_templates (machine_id);

;
CREATE INDEX job_templates_idx_product_id02 ON job_templates (product_id);

;
CREATE INDEX job_templates_idx_test_suit00 ON job_templates (test_suite_id);

;
CREATE UNIQUE INDEX job_templates_product_id_ma00 ON job_templates (product_id, machine_id, test_suite_id);

;
INSERT INTO job_templates SELECT id, product_id, machine_id, test_suite_id, prio, group_id, t_created, t_updated FROM job_templates_temp_alter;

;
DROP TABLE job_templates_temp_alter;

;
CREATE TEMPORARY TABLE test_suites_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO test_suites_temp_alter( id, name, variables, t_created, t_updated) SELECT id, name, variables, t_created, t_updated FROM test_suites;

;
DROP TABLE test_suites;

;
CREATE TABLE test_suites (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX test_suites_name02 ON test_suites (name);

;
INSERT INTO test_suites SELECT id, name, variables, t_created, t_updated FROM test_suites_temp_alter;

;
DROP TABLE test_suites_temp_alter;

;

COMMIT;

