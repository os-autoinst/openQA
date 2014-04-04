-- Convert schema '/home/antonio/github/antlarr/openQA/script/../dbicdh/_source/deploy/3/001-auto.yml' to '/home/antonio/github/antlarr/openQA/script/../dbicdh/_source/deploy/4/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_templates (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  machine_id integer NOT NULL,
  test_suite_id integer NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_templates_idx_machine_id ON job_templates (machine_id);

;
CREATE INDEX job_templates_idx_product_id ON job_templates (product_id);

;
CREATE INDEX job_templates_idx_test_suite_id ON job_templates (test_suite_id);

;
CREATE UNIQUE INDEX job_templates_product_id_machine_id_test_suite_id ON job_templates (product_id, machine_id, test_suite_id);

;
CREATE TABLE machines (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  backend text NOT NULL,
  variables text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);

;
CREATE UNIQUE INDEX machines_name ON machines (name);

;
CREATE TABLE products (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  distri text NOT NULL,
  arch text NOT NULL,
  flavor text NOT NULL,
  variables text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);

;
CREATE UNIQUE INDEX products_distri_arch_flavor ON products (distri, arch, flavor);

;
CREATE UNIQUE INDEX products_name ON products (name);

;
CREATE TABLE test_suites (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  variables text NOT NULL,
  prio integer NOT NULL,
  t_created timestamp,
  t_updated timestamp
);

;
CREATE UNIQUE INDEX test_suites_name ON test_suites (name);

;

COMMIT;

