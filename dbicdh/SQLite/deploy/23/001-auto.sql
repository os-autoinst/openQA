-- 
-- Created by SQL::Translator::Producer::SQLite
-- Created on Thu Jan 29 13:20:33 2015
-- 

;
BEGIN TRANSACTION;
--
-- Table: assets
--
CREATE TABLE assets (
  id INTEGER PRIMARY KEY NOT NULL,
  type text NOT NULL,
  name text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX assets_type_name ON assets (type, name);
--
-- Table: job_modules
--
CREATE TABLE job_modules (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer NOT NULL,
  name text NOT NULL,
  script text NOT NULL,
  category text NOT NULL,
  result varchar NOT NULL DEFAULT 'none',
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_modules_idx_job_id ON job_modules (job_id);
CREATE INDEX idx_job_modules_result ON job_modules (result);
--
-- Table: job_settings
--
CREATE TABLE job_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  job_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_settings_idx_job_id ON job_settings (job_id);
--
-- Table: machine_settings
--
CREATE TABLE machine_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  machine_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX machine_settings_idx_machine_id ON machine_settings (machine_id);
CREATE UNIQUE INDEX machine_settings_machine_id_key ON machine_settings (machine_id, key);
--
-- Table: machines
--
CREATE TABLE machines (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  backend text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX machines_name ON machines (name);
--
-- Table: product_settings
--
CREATE TABLE product_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX product_settings_idx_product_id ON product_settings (product_id);
CREATE UNIQUE INDEX product_settings_product_id_key ON product_settings (product_id, key);
--
-- Table: products
--
CREATE TABLE products (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  distri text NOT NULL,
  version text NOT NULL DEFAULT '',
  arch text NOT NULL,
  flavor text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX products_distri_version_arch_flavor ON products (distri, version, arch, flavor);
--
-- Table: secrets
--
CREATE TABLE secrets (
  id INTEGER PRIMARY KEY NOT NULL,
  secret text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX secrets_secret ON secrets (secret);
--
-- Table: test_suite_settings
--
CREATE TABLE test_suite_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  test_suite_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX test_suite_settings_idx_test_suite_id ON test_suite_settings (test_suite_id);
CREATE UNIQUE INDEX test_suite_settings_test_suite_id_key ON test_suite_settings (test_suite_id, key);
--
-- Table: test_suites
--
CREATE TABLE test_suites (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  variables text NOT NULL,
  prio integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX test_suites_name ON test_suites (name);
--
-- Table: users
--
CREATE TABLE users (
  id INTEGER PRIMARY KEY NOT NULL,
  username text NOT NULL,
  email text,
  fullname text,
  nickname text,
  is_operator integer NOT NULL DEFAULT 0,
  is_admin integer NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX users_username ON users (username);
--
-- Table: worker_properties
--
CREATE TABLE worker_properties (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  worker_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX worker_properties_idx_worker_id ON worker_properties (worker_id);
--
-- Table: workers
--
CREATE TABLE workers (
  id INTEGER PRIMARY KEY NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  backend text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX workers_host_instance ON workers (host, instance);
--
-- Table: api_keys
--
CREATE TABLE api_keys (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  secret text NOT NULL,
  user_id integer NOT NULL,
  t_expiration timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX api_keys_idx_user_id ON api_keys (user_id);
CREATE UNIQUE INDEX api_keys_key ON api_keys (key);
--
-- Table: jobs
--
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY NOT NULL,
  slug text,
  state varchar NOT NULL DEFAULT 'scheduled',
  priority integer NOT NULL DEFAULT 50,
  result varchar NOT NULL DEFAULT 'none',
  worker_id integer NOT NULL DEFAULT 0,
  test text NOT NULL,
  test_branch text,
  clone_id integer,
  retry_avbl integer NOT NULL DEFAULT 3,
  t_started timestamp,
  t_finished timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (clone_id) REFERENCES jobs(id) ON DELETE SET NULL,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX jobs_idx_clone_id ON jobs (clone_id);
CREATE INDEX jobs_idx_worker_id ON jobs (worker_id);
CREATE INDEX idx_jobs_state ON jobs (state);
CREATE INDEX idx_jobs_result ON jobs (result);
CREATE UNIQUE INDEX jobs_slug ON jobs (slug);
--
-- Table: job_dependencies
--
CREATE TABLE job_dependencies (
  child_job_id integer NOT NULL,
  parent_job_id integer NOT NULL,
  dependency integer NOT NULL,
  PRIMARY KEY (child_job_id, parent_job_id, dependency),
  FOREIGN KEY (child_job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (parent_job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_dependencies_idx_child_job_id ON job_dependencies (child_job_id);
CREATE INDEX job_dependencies_idx_parent_job_id ON job_dependencies (parent_job_id);
CREATE INDEX idx_job_dependencies_dependency ON job_dependencies (dependency);
--
-- Table: job_templates
--
CREATE TABLE job_templates (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  machine_id integer NOT NULL,
  test_suite_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_templates_idx_machine_id ON job_templates (machine_id);
CREATE INDEX job_templates_idx_product_id ON job_templates (product_id);
CREATE INDEX job_templates_idx_test_suite_id ON job_templates (test_suite_id);
CREATE UNIQUE INDEX job_templates_product_id_machine_id_test_suite_id ON job_templates (product_id, machine_id, test_suite_id);
--
-- Table: jobs_assets
--
CREATE TABLE jobs_assets (
  job_id integer NOT NULL,
  asset_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (asset_id) REFERENCES assets(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX jobs_assets_idx_asset_id ON jobs_assets (asset_id);
CREATE INDEX jobs_assets_idx_job_id ON jobs_assets (job_id);
CREATE UNIQUE INDEX jobs_assets_job_id_asset_id ON jobs_assets (job_id, asset_id);
COMMIT;
