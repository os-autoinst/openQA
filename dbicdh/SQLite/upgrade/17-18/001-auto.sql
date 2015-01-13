-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/17/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/18/001-auto.yml':;

;
BEGIN;

;
CREATE TEMPORARY TABLE api_keys_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  secret text NOT NULL,
  user_id integer NOT NULL,
  t_expiration timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO api_keys_temp_alter( id, key, secret, user_id, t_expiration, t_created, t_updated) SELECT id, key, secret, user_id, t_expiration, t_created, t_updated FROM api_keys;

;
DROP TABLE api_keys;

;
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

;
CREATE INDEX api_keys_idx_user_id02 ON api_keys (user_id);

;
CREATE UNIQUE INDEX api_keys_key02 ON api_keys (key);

;
INSERT INTO api_keys SELECT id, key, secret, user_id, t_expiration, t_created, t_updated FROM api_keys_temp_alter;

;
DROP TABLE api_keys_temp_alter;

;
CREATE TEMPORARY TABLE assets_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  type text NOT NULL,
  name text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO assets_temp_alter( id, type, name, t_created, t_updated) SELECT id, type, name, t_created, t_updated FROM assets;

;
DROP TABLE assets;

;
CREATE TABLE assets (
  id INTEGER PRIMARY KEY NOT NULL,
  type text NOT NULL,
  name text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX assets_type_name02 ON assets (type, name);

;
INSERT INTO assets SELECT id, type, name, t_created, t_updated FROM assets_temp_alter;

;
DROP TABLE assets_temp_alter;

;
CREATE TEMPORARY TABLE commands_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  command text NOT NULL,
  t_processed timestamp,
  worker_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO commands_temp_alter( id, command, t_processed, worker_id, t_created, t_updated) SELECT id, command, t_processed, worker_id, t_created, t_updated FROM commands;

;
DROP TABLE commands;

;
CREATE TABLE commands (
  id INTEGER PRIMARY KEY NOT NULL,
  command text NOT NULL,
  t_processed timestamp,
  worker_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX commands_idx_worker_id02 ON commands (worker_id);

;
INSERT INTO commands SELECT id, command, t_processed, worker_id, t_created, t_updated FROM commands_temp_alter;

;
DROP TABLE commands_temp_alter;

;
CREATE TEMPORARY TABLE job_modules_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer NOT NULL,
  name text NOT NULL,
  script text NOT NULL,
  category text NOT NULL,
  result_id integer NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (result_id) REFERENCES job_results(id)
);

;
INSERT INTO job_modules_temp_alter( id, job_id, name, script, category, result_id, t_created, t_updated) SELECT id, job_id, name, script, category, result_id, t_created, t_updated FROM job_modules;

;
DROP TABLE job_modules;

;
CREATE TABLE job_modules (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer NOT NULL,
  name text NOT NULL,
  script text NOT NULL,
  category text NOT NULL,
  result_id integer NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (result_id) REFERENCES job_results(id)
);

;
CREATE INDEX job_modules_idx_job_id02 ON job_modules (job_id);

;
CREATE INDEX job_modules_idx_result_id02 ON job_modules (result_id);

;
INSERT INTO job_modules SELECT id, job_id, name, script, category, result_id, t_created, t_updated FROM job_modules_temp_alter;

;
DROP TABLE job_modules_temp_alter;

;
CREATE TEMPORARY TABLE job_settings_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  job_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO job_settings_temp_alter( id, key, value, job_id, t_created, t_updated) SELECT id, key, value, job_id, t_created, t_updated FROM job_settings;

;
DROP TABLE job_settings;

;
CREATE TABLE job_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  job_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_settings_idx_job_id02 ON job_settings (job_id);

;
INSERT INTO job_settings SELECT id, key, value, job_id, t_created, t_updated FROM job_settings_temp_alter;

;
DROP TABLE job_settings_temp_alter;

;
CREATE TEMPORARY TABLE job_templates_temp_alter (
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

;
INSERT INTO job_templates_temp_alter( id, product_id, machine_id, test_suite_id, t_created, t_updated) SELECT id, product_id, machine_id, test_suite_id, t_created, t_updated FROM job_templates;

;
DROP TABLE job_templates;

;
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

;
CREATE INDEX job_templates_idx_machine_id02 ON job_templates (machine_id);

;
CREATE INDEX job_templates_idx_product_id02 ON job_templates (product_id);

;
CREATE INDEX job_templates_idx_test_suit00 ON job_templates (test_suite_id);

;
CREATE UNIQUE INDEX job_templates_product_id_ma00 ON job_templates (product_id, machine_id, test_suite_id);

;
INSERT INTO job_templates SELECT id, product_id, machine_id, test_suite_id, t_created, t_updated FROM job_templates_temp_alter;

;
DROP TABLE job_templates_temp_alter;

;
CREATE TEMPORARY TABLE jobs_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  slug text,
  state_id integer NOT NULL DEFAULT 0,
  priority integer NOT NULL DEFAULT 50,
  result_id integer NOT NULL DEFAULT 0,
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
  FOREIGN KEY (result_id) REFERENCES job_results(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (state_id) REFERENCES job_states(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO jobs_temp_alter( id, slug, state_id, priority, result_id, worker_id, test, test_branch, clone_id, retry_avbl, t_started, t_finished, t_created, t_updated) SELECT id, slug, state_id, priority, result_id, worker_id, test, test_branch, clone_id, retry_avbl, t_started, t_finished, t_created, t_updated FROM jobs;

;
DROP TABLE jobs;

;
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY NOT NULL,
  slug text,
  state_id integer NOT NULL DEFAULT 0,
  priority integer NOT NULL DEFAULT 50,
  result_id integer NOT NULL DEFAULT 0,
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
  FOREIGN KEY (result_id) REFERENCES job_results(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (state_id) REFERENCES job_states(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX jobs_idx_clone_id02 ON jobs (clone_id);

;
CREATE INDEX jobs_idx_result_id02 ON jobs (result_id);

;
CREATE INDEX jobs_idx_state_id02 ON jobs (state_id);

;
CREATE INDEX jobs_idx_worker_id02 ON jobs (worker_id);

;
CREATE UNIQUE INDEX jobs_slug02 ON jobs (slug);

;
INSERT INTO jobs SELECT id, slug, state_id, priority, result_id, worker_id, test, test_branch, clone_id, retry_avbl, t_started, t_finished, t_created, t_updated FROM jobs_temp_alter;

;
DROP TABLE jobs_temp_alter;

;
CREATE TEMPORARY TABLE jobs_assets_temp_alter (
  job_id integer NOT NULL,
  asset_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (asset_id) REFERENCES assets(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO jobs_assets_temp_alter( job_id, asset_id, t_created, t_updated) SELECT job_id, asset_id, t_created, t_updated FROM jobs_assets;

;
DROP TABLE jobs_assets;

;
CREATE TABLE jobs_assets (
  job_id integer NOT NULL,
  asset_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (asset_id) REFERENCES assets(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX jobs_assets_idx_asset_id02 ON jobs_assets (asset_id);

;
CREATE INDEX jobs_assets_idx_job_id02 ON jobs_assets (job_id);

;
CREATE UNIQUE INDEX jobs_assets_job_id_asset_id02 ON jobs_assets (job_id, asset_id);

;
INSERT INTO jobs_assets SELECT job_id, asset_id, t_created, t_updated FROM jobs_assets_temp_alter;

;
DROP TABLE jobs_assets_temp_alter;

;
CREATE TEMPORARY TABLE machine_settings_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  machine_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO machine_settings_temp_alter( id, machine_id, key, value, t_created, t_updated) SELECT id, machine_id, key, value, t_created, t_updated FROM machine_settings;

;
DROP TABLE machine_settings;

;
CREATE TABLE machine_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  machine_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX machine_settings_idx_machin00 ON machine_settings (machine_id);

;
CREATE UNIQUE INDEX machine_settings_machine_id00 ON machine_settings (machine_id, key);

;
INSERT INTO machine_settings SELECT id, machine_id, key, value, t_created, t_updated FROM machine_settings_temp_alter;

;
DROP TABLE machine_settings_temp_alter;

;
CREATE TEMPORARY TABLE machines_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  backend text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO machines_temp_alter( id, name, backend, variables, t_created, t_updated) SELECT id, name, backend, variables, t_created, t_updated FROM machines;

;
DROP TABLE machines;

;
CREATE TABLE machines (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  backend text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX machines_name02 ON machines (name);

;
INSERT INTO machines SELECT id, name, backend, variables, t_created, t_updated FROM machines_temp_alter;

;
DROP TABLE machines_temp_alter;

;
CREATE TEMPORARY TABLE product_settings_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO product_settings_temp_alter( id, product_id, key, value, t_created, t_updated) SELECT id, product_id, key, value, t_created, t_updated FROM product_settings;

;
DROP TABLE product_settings;

;
CREATE TABLE product_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX product_settings_idx_produc00 ON product_settings (product_id);

;
CREATE UNIQUE INDEX product_settings_product_id00 ON product_settings (product_id, key);

;
INSERT INTO product_settings SELECT id, product_id, key, value, t_created, t_updated FROM product_settings_temp_alter;

;
DROP TABLE product_settings_temp_alter;

;
CREATE TEMPORARY TABLE products_temp_alter (
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

;
INSERT INTO products_temp_alter( id, name, distri, version, arch, flavor, variables, t_created, t_updated) SELECT id, name, distri, version, arch, flavor, variables, t_created, t_updated FROM products;

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
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX products_distri_version_arc00 ON products (distri, version, arch, flavor);

;
INSERT INTO products SELECT id, name, distri, version, arch, flavor, variables, t_created, t_updated FROM products_temp_alter;

;
DROP TABLE products_temp_alter;

;
CREATE TEMPORARY TABLE secrets_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  secret text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO secrets_temp_alter( id, secret, t_created, t_updated) SELECT id, secret, t_created, t_updated FROM secrets;

;
DROP TABLE secrets;

;
CREATE TABLE secrets (
  id INTEGER PRIMARY KEY NOT NULL,
  secret text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX secrets_secret02 ON secrets (secret);

;
INSERT INTO secrets SELECT id, secret, t_created, t_updated FROM secrets_temp_alter;

;
DROP TABLE secrets_temp_alter;

;
CREATE TEMPORARY TABLE test_suite_settings_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  test_suite_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO test_suite_settings_temp_alter( id, test_suite_id, key, value, t_created, t_updated) SELECT id, test_suite_id, key, value, t_created, t_updated FROM test_suite_settings;

;
DROP TABLE test_suite_settings;

;
CREATE TABLE test_suite_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  test_suite_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX test_suite_settings_idx_tes00 ON test_suite_settings (test_suite_id);

;
CREATE UNIQUE INDEX test_suite_settings_test_su00 ON test_suite_settings (test_suite_id, key);

;
INSERT INTO test_suite_settings SELECT id, test_suite_id, key, value, t_created, t_updated FROM test_suite_settings_temp_alter;

;
DROP TABLE test_suite_settings_temp_alter;

;
CREATE TEMPORARY TABLE test_suites_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  variables text NOT NULL,
  prio integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO test_suites_temp_alter( id, name, variables, prio, t_created, t_updated) SELECT id, name, variables, prio, t_created, t_updated FROM test_suites;

;
DROP TABLE test_suites;

;
CREATE TABLE test_suites (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  variables text NOT NULL,
  prio integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX test_suites_name02 ON test_suites (name);

;
INSERT INTO test_suites SELECT id, name, variables, prio, t_created, t_updated FROM test_suites_temp_alter;

;
DROP TABLE test_suites_temp_alter;

;
CREATE TEMPORARY TABLE users_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  openid text NOT NULL,
  email text,
  fullname text,
  nickname text,
  is_operator integer NOT NULL DEFAULT 0,
  is_admin integer NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO users_temp_alter( id, openid, email, fullname, nickname, is_operator, is_admin, t_created, t_updated) SELECT id, openid, email, fullname, nickname, is_operator, is_admin, t_created, t_updated FROM users;

;
DROP TABLE users;

;
CREATE TABLE users (
  id INTEGER PRIMARY KEY NOT NULL,
  openid text NOT NULL,
  email text,
  fullname text,
  nickname text,
  is_operator integer NOT NULL DEFAULT 0,
  is_admin integer NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX users_openid02 ON users (openid);

;
INSERT INTO users SELECT id, openid, email, fullname, nickname, is_operator, is_admin, t_created, t_updated FROM users_temp_alter;

;
DROP TABLE users_temp_alter;

;
CREATE TEMPORARY TABLE worker_properties_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  worker_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO worker_properties_temp_alter( id, key, value, worker_id, t_created, t_updated) SELECT id, key, value, worker_id, t_created, t_updated FROM worker_properties;

;
DROP TABLE worker_properties;

;
CREATE TABLE worker_properties (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  worker_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX worker_properties_idx_worke00 ON worker_properties (worker_id);

;
INSERT INTO worker_properties SELECT id, key, value, worker_id, t_created, t_updated FROM worker_properties_temp_alter;

;
DROP TABLE worker_properties_temp_alter;

;
CREATE TEMPORARY TABLE workers_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  backend text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO workers_temp_alter( id, host, instance, backend, t_created, t_updated) SELECT id, host, instance, backend, t_created, t_updated FROM workers;

;
DROP TABLE workers;

;
CREATE TABLE workers (
  id INTEGER PRIMARY KEY NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  backend text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX workers_host_instance02 ON workers (host, instance);

;
INSERT INTO workers SELECT id, host, instance, backend, t_created, t_updated FROM workers_temp_alter;

;
DROP TABLE workers_temp_alter;

;

COMMIT;

