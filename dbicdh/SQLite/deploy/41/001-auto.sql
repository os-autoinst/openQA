-- 
-- Created by SQL::Translator::Producer::SQLite
-- Created on Tue Jul 26 15:03:06 2016
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
  size bigint,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX assets_type_name ON assets (type, name);
--
-- Table: gru_tasks
--
CREATE TABLE gru_tasks (
  id INTEGER PRIMARY KEY NOT NULL,
  taskname text NOT NULL,
  args text NOT NULL,
  run_at datetime NOT NULL,
  priority integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
--
-- Table: job_groups
--
CREATE TABLE job_groups (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  size_limit_gb integer NOT NULL DEFAULT 100,
  keep_logs_in_days integer NOT NULL DEFAULT 30,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);
CREATE UNIQUE INDEX job_groups_name ON job_groups (name);
--
-- Table: job_modules
--
CREATE TABLE job_modules (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer NOT NULL,
  name text NOT NULL,
  script text NOT NULL,
  category text NOT NULL,
  milestone integer NOT NULL DEFAULT 0,
  important integer NOT NULL DEFAULT 0,
  fatal integer NOT NULL DEFAULT 0,
  result varchar NOT NULL DEFAULT 'none',
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON UPDATE CASCADE
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
CREATE INDEX idx_value_settings ON job_settings (key, value);
CREATE INDEX idx_job_id_value_settings ON job_settings (job_id, key, value);
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
-- Table: needle_dirs
--
CREATE TABLE needle_dirs (
  id INTEGER PRIMARY KEY NOT NULL,
  path text NOT NULL,
  name text NOT NULL
);
CREATE UNIQUE INDEX needle_dirs_path ON needle_dirs (path);
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
-- Table: audit_events
--
CREATE TABLE audit_events (
  id INTEGER PRIMARY KEY NOT NULL,
  user_id integer,
  connection_id text,
  event text NOT NULL,
  event_data text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX audit_events_idx_user_id ON audit_events (user_id);
--
-- Table: comments
--
CREATE TABLE comments (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer,
  group_id integer,
  text text NOT NULL,
  user_id integer NOT NULL,
  hidden boolean NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX comments_idx_group_id ON comments (group_id);
CREATE INDEX comments_idx_job_id ON comments (job_id);
CREATE INDEX comments_idx_user_id ON comments (user_id);
--
-- Table: jobs
--
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY NOT NULL,
  slug text,
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
  t_started timestamp,
  t_finished timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (clone_id) REFERENCES jobs(id) ON DELETE SET NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE INDEX jobs_idx_clone_id ON jobs (clone_id);
CREATE INDEX jobs_idx_group_id ON jobs (group_id);
CREATE INDEX idx_jobs_state ON jobs (state);
CREATE INDEX idx_jobs_result ON jobs (result);
CREATE INDEX idx_jobs_build_group ON jobs (BUILD, group_id);
CREATE INDEX idx_jobs_scenario ON jobs (VERSION, DISTRI, FLAVOR, TEST, MACHINE, ARCH);
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
-- Table: job_locks
--
CREATE TABLE job_locks (
  name text NOT NULL,
  owner integer NOT NULL,
  locked_by integer,
  PRIMARY KEY (name, owner),
  FOREIGN KEY (locked_by) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (owner) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_locks_idx_locked_by ON job_locks (locked_by);
CREATE INDEX job_locks_idx_owner ON job_locks (owner);
--
-- Table: job_networks
--
CREATE TABLE job_networks (
  name text NOT NULL,
  job_id integer NOT NULL,
  vlan integer NOT NULL,
  PRIMARY KEY (name, job_id),
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_networks_idx_job_id ON job_networks (job_id);
--
-- Table: needles
--
CREATE TABLE needles (
  id INTEGER PRIMARY KEY NOT NULL,
  dir_id integer NOT NULL,
  filename text NOT NULL,
  first_seen_module_id integer NOT NULL,
  last_seen_module_id integer NOT NULL,
  last_matched_module_id integer,
  file_present boolean NOT NULL DEFAULT 1,
  FOREIGN KEY (dir_id) REFERENCES needle_dirs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (first_seen_module_id) REFERENCES job_modules(id),
  FOREIGN KEY (last_matched_module_id) REFERENCES job_modules(id),
  FOREIGN KEY (last_seen_module_id) REFERENCES job_modules(id)
);
CREATE INDEX needles_idx_dir_id ON needles (dir_id);
CREATE INDEX needles_idx_first_seen_module_id ON needles (first_seen_module_id);
CREATE INDEX needles_idx_last_matched_module_id ON needles (last_matched_module_id);
CREATE INDEX needles_idx_last_seen_module_id ON needles (last_seen_module_id);
CREATE UNIQUE INDEX needles_dir_id_filename ON needles (dir_id, filename);
--
-- Table: workers
--
CREATE TABLE workers (
  id INTEGER PRIMARY KEY NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  job_id integer,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE
);
CREATE INDEX workers_idx_job_id ON workers (job_id);
CREATE UNIQUE INDEX workers_host_instance ON workers (host, instance);
CREATE UNIQUE INDEX workers_job_id ON workers (job_id);
--
-- Table: gru_dependencies
--
CREATE TABLE gru_dependencies (
  job_id integer NOT NULL,
  gru_task_id integer NOT NULL,
  PRIMARY KEY (job_id, gru_task_id),
  FOREIGN KEY (gru_task_id) REFERENCES gru_tasks(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX gru_dependencies_idx_gru_task_id ON gru_dependencies (gru_task_id);
CREATE INDEX gru_dependencies_idx_job_id ON gru_dependencies (job_id);
--
-- Table: job_module_needles
--
CREATE TABLE job_module_needles (
  needle_id integer NOT NULL,
  job_module_id integer NOT NULL,
  matched boolean NOT NULL DEFAULT 1,
  FOREIGN KEY (job_module_id) REFERENCES job_modules(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (needle_id) REFERENCES needles(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_module_needles_idx_job_module_id ON job_module_needles (job_module_id);
CREATE INDEX job_module_needles_idx_needle_id ON job_module_needles (needle_id);
CREATE UNIQUE INDEX job_module_needles_needle_id_job_module_id ON job_module_needles (needle_id, job_module_id);
--
-- Table: jobs_assets
--
CREATE TABLE jobs_assets (
  job_id integer NOT NULL,
  asset_id integer NOT NULL,
  created_by boolean NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (asset_id) REFERENCES assets(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX jobs_assets_idx_asset_id ON jobs_assets (asset_id);
CREATE INDEX jobs_assets_idx_job_id ON jobs_assets (job_id);
CREATE UNIQUE INDEX jobs_assets_job_id_asset_id ON jobs_assets (job_id, asset_id);
--
-- Table: job_templates
--
CREATE TABLE job_templates (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  machine_id integer NOT NULL,
  test_suite_id integer NOT NULL,
  prio integer NOT NULL,
  group_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id),
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_templates_idx_group_id ON job_templates (group_id);
CREATE INDEX job_templates_idx_machine_id ON job_templates (machine_id);
CREATE INDEX job_templates_idx_product_id ON job_templates (product_id);
CREATE INDEX job_templates_idx_test_suite_id ON job_templates (test_suite_id);
CREATE UNIQUE INDEX job_templates_product_id_machine_id_test_suite_id ON job_templates (product_id, machine_id, test_suite_id);
COMMIT;
