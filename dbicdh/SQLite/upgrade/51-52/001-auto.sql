-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/51/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/52/001-auto.yml':;

;
BEGIN;

;
CREATE TEMPORARY TABLE jobs_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  result_dir text,
  state varchar NOT NULL DEFAULT 'scheduled',
  priority integer NOT NULL DEFAULT 50,
  result varchar NOT NULL DEFAULT 'none',
  clone_id integer,
  retry_avbl integer NOT NULL DEFAULT 3,
  backend varchar,
  backend_info text,
  TEST text,
  DISTRI text,
  VERSION text,
  FLAVOR text,
  ARCH text,
  BUILD text,
  MACHINE text,
  group_id integer,
  assigned_worker_id integer,
  t_started timestamp,
  t_finished timestamp,
  logs_present boolean NOT NULL DEFAULT 1,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (assigned_worker_id) REFERENCES workers(id) ON DELETE SET NULL,
  FOREIGN KEY (clone_id) REFERENCES jobs(id) ON DELETE SET NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE SET NULL ON UPDATE CASCADE
);

;
INSERT INTO jobs_temp_alter( id, result_dir, state, priority, result, clone_id, retry_avbl, backend, backend_info, TEST, DISTRI, VERSION, FLAVOR, ARCH, BUILD, MACHINE, group_id, assigned_worker_id, t_started, t_finished, logs_present, t_created, t_updated) SELECT id, result_dir, state, priority, result, clone_id, retry_avbl, backend, backend_info, TEST, DISTRI, VERSION, FLAVOR, ARCH, BUILD, MACHINE, group_id, assigned_worker_id, t_started, t_finished, logs_present, t_created, t_updated FROM jobs;

;
DROP TABLE jobs;

;
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY NOT NULL,
  result_dir text,
  state varchar NOT NULL DEFAULT 'scheduled',
  priority integer NOT NULL DEFAULT 50,
  result varchar NOT NULL DEFAULT 'none',
  clone_id integer,
  retry_avbl integer NOT NULL DEFAULT 3,
  backend varchar,
  backend_info text,
  TEST text,
  DISTRI text,
  VERSION text,
  FLAVOR text,
  ARCH text,
  BUILD text,
  MACHINE text,
  group_id integer,
  assigned_worker_id integer,
  t_started timestamp,
  t_finished timestamp,
  logs_present boolean NOT NULL DEFAULT 1,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (assigned_worker_id) REFERENCES workers(id) ON DELETE SET NULL,
  FOREIGN KEY (clone_id) REFERENCES jobs(id) ON DELETE SET NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE SET NULL ON UPDATE CASCADE
);

;
CREATE INDEX jobs_idx_assigned_worker_id02 ON jobs (assigned_worker_id);

;
CREATE INDEX jobs_idx_clone_id02 ON jobs (clone_id);

;
CREATE INDEX jobs_idx_group_id02 ON jobs (group_id);

;
CREATE INDEX idx_jobs_state02 ON jobs (state);

;
CREATE INDEX idx_jobs_result02 ON jobs (result);

;
CREATE INDEX idx_jobs_build_group02 ON jobs (BUILD, group_id);

;
CREATE INDEX idx_jobs_scenario02 ON jobs (VERSION, DISTRI, FLAVOR, TEST, MACHINE, ARCH);

;
INSERT INTO jobs SELECT id, result_dir, state, priority, result, clone_id, retry_avbl, backend, backend_info, TEST, DISTRI, VERSION, FLAVOR, ARCH, BUILD, MACHINE, group_id, assigned_worker_id, t_started, t_finished, logs_present, t_created, t_updated FROM jobs_temp_alter;

;
DROP TABLE jobs_temp_alter;

;
CREATE TEMPORARY TABLE machines_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  backend text NOT NULL,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO machines_temp_alter( id, name, backend, t_created, t_updated) SELECT id, name, backend, t_created, t_updated FROM machines;

;
DROP TABLE machines;

;
CREATE TABLE machines (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  backend text NOT NULL,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX machines_name02 ON machines (name);

;
INSERT INTO machines SELECT id, name, backend, description, t_created, t_updated FROM machines_temp_alter;

;
DROP TABLE machines_temp_alter;

;
CREATE TEMPORARY TABLE products_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  distri text NOT NULL,
  version text NOT NULL DEFAULT '',
  arch text NOT NULL,
  flavor text NOT NULL,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO products_temp_alter( id, name, distri, version, arch, flavor, t_created, t_updated) SELECT id, name, distri, version, arch, flavor, t_created, t_updated FROM products;

;
DROP TABLE products;

;
CREATE TABLE products (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  distri text NOT NULL,
  version text NOT NULL DEFAULT '',
  arch text NOT NULL,
  flavor text NOT NULL,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX products_distri_version_arc00 ON products (distri, version, arch, flavor);

;
INSERT INTO products SELECT id, name, distri, version, arch, flavor, description, t_created, t_updated FROM products_temp_alter;

;
DROP TABLE products_temp_alter;

;
CREATE TEMPORARY TABLE test_suites_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO test_suites_temp_alter( id, name, t_created, t_updated) SELECT id, name, t_created, t_updated FROM test_suites;

;
DROP TABLE test_suites;

;
CREATE TABLE test_suites (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  description text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX test_suites_name02 ON test_suites (name);

;
INSERT INTO test_suites SELECT id, name, description, t_created, t_updated FROM test_suites_temp_alter;

;
DROP TABLE test_suites_temp_alter;

;

COMMIT;
