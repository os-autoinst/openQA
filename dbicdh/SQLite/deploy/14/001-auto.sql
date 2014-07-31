-- 
-- Created by SQL::Translator::Producer::SQLite
-- Created on Thu Jul 31 13:43:30 2014
-- 

;
BEGIN TRANSACTION;
--
-- Table: assets
--
DROP TABLE IF EXISTS assets;
CREATE TABLE assets (
  id INTEGER PRIMARY KEY NOT NULL,
  type text NOT NULL,
  name text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX assets_type_name ON assets (type, name);
--
-- Table: job_results
--
DROP TABLE IF EXISTS job_results;
CREATE TABLE job_results (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL
);
--
-- Table: job_settings
--
DROP TABLE IF EXISTS job_settings;
CREATE TABLE job_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  job_id integer NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_settings_idx_job_id ON job_settings (job_id);
CREATE INDEX job_settings_kv_index ON job_settings (key, value);
--
-- Table: job_states
--
DROP TABLE IF EXISTS job_states;
CREATE TABLE job_states (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL
);
--
-- Table: machine_settings
--
DROP TABLE IF EXISTS machine_settings;
CREATE TABLE machine_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  machine_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX machine_settings_idx_machine_id ON machine_settings (machine_id);
CREATE UNIQUE INDEX machine_settings_machine_id_key ON machine_settings (machine_id, key);
--
-- Table: machines
--
DROP TABLE IF EXISTS machines;
CREATE TABLE machines (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  backend text NOT NULL,
  variables text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX machines_name ON machines (name);
--
-- Table: product_settings
--
DROP TABLE IF EXISTS product_settings;
CREATE TABLE product_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX product_settings_idx_product_id ON product_settings (product_id);
CREATE UNIQUE INDEX product_settings_product_id_key ON product_settings (product_id, key);
--
-- Table: products
--
DROP TABLE IF EXISTS products;
CREATE TABLE products (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  distri text NOT NULL,
  version text NOT NULL DEFAULT '',
  arch text NOT NULL,
  flavor text NOT NULL,
  variables text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX products_distri_version_arch_flavor ON products (distri, version, arch, flavor);
--
-- Table: secrets
--
DROP TABLE IF EXISTS secrets;
CREATE TABLE secrets (
  id INTEGER PRIMARY KEY NOT NULL,
  secret text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX constraint_name ON secrets (secret);
--
-- Table: test_suite_settings
--
DROP TABLE IF EXISTS test_suite_settings;
CREATE TABLE test_suite_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  test_suite_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX test_suite_settings_idx_test_suite_id ON test_suite_settings (test_suite_id);
CREATE UNIQUE INDEX test_suite_settings_test_suite_id_key ON test_suite_settings (test_suite_id, key);
--
-- Table: test_suites
--
DROP TABLE IF EXISTS test_suites;
CREATE TABLE test_suites (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL,
  variables text NOT NULL,
  prio integer NOT NULL,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX test_suites_name ON test_suites (name);
--
-- Table: users
--
DROP TABLE IF EXISTS users;
CREATE TABLE users (
  id INTEGER PRIMARY KEY NOT NULL,
  openid text NOT NULL,
  email text,
  fullname text,
  nickname text,
  is_operator integer NOT NULL DEFAULT 0,
  is_admin integer NOT NULL DEFAULT 0,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX constraint_name02 ON users (openid);
--
-- Table: workers
--
DROP TABLE IF EXISTS workers;
CREATE TABLE workers (
  id INTEGER PRIMARY KEY NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  backend text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX constraint_name03 ON workers (host, instance);
--
-- Table: api_keys
--
DROP TABLE IF EXISTS api_keys;
CREATE TABLE api_keys (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  secret text NOT NULL,
  user_id integer NOT NULL,
  t_expiration timestamp,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX api_keys_idx_user_id ON api_keys (user_id);
CREATE UNIQUE INDEX constraint_name04 ON api_keys (key);
--
-- Table: commands
--
DROP TABLE IF EXISTS commands;
CREATE TABLE commands (
  id INTEGER PRIMARY KEY NOT NULL,
  command text NOT NULL,
  t_processed timestamp,
  worker_id integer NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX commands_idx_worker_id ON commands (worker_id);
--
-- Table: job_templates
--
DROP TABLE IF EXISTS job_templates;
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
CREATE INDEX job_templates_idx_machine_id ON job_templates (machine_id);
CREATE INDEX job_templates_idx_product_id ON job_templates (product_id);
CREATE INDEX job_templates_idx_test_suite_id ON job_templates (test_suite_id);
CREATE UNIQUE INDEX job_templates_product_id_machine_id_test_suite_id ON job_templates (product_id, machine_id, test_suite_id);
--
-- Table: jobs
--
DROP TABLE IF EXISTS jobs;
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
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (clone_id) REFERENCES jobs(id) ON DELETE SET NULL,
  FOREIGN KEY (result_id) REFERENCES job_results(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (state_id) REFERENCES job_states(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX jobs_idx_clone_id ON jobs (clone_id);
CREATE INDEX jobs_idx_result_id ON jobs (result_id);
CREATE INDEX jobs_idx_state_id ON jobs (state_id);
CREATE INDEX jobs_idx_worker_id ON jobs (worker_id);
CREATE UNIQUE INDEX constraint_name05 ON jobs (slug);
--
-- Table: jobs_assets
--
DROP TABLE IF EXISTS jobs_assets;
CREATE TABLE jobs_assets (
  job_id integer NOT NULL,
  asset_id integer NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (asset_id) REFERENCES assets(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX jobs_assets_idx_asset_id ON jobs_assets (asset_id);
CREATE INDEX jobs_assets_idx_job_id ON jobs_assets (job_id);
CREATE UNIQUE INDEX constraint_name06 ON jobs_assets (job_id, asset_id);
DROP TRIGGER IF EXISTS trigger_assets_t_created;
CREATE TRIGGER trigger_assets_t_created after insert on assets BEGIN UPDATE assets SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_assets_t_updated;
CREATE TRIGGER trigger_assets_t_updated after update on assets BEGIN UPDATE assets SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_job_settings_t_created;
CREATE TRIGGER trigger_job_settings_t_created after insert on job_settings BEGIN UPDATE job_settings SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_job_settings_t_updated;
CREATE TRIGGER trigger_job_settings_t_updated after update on job_settings BEGIN UPDATE job_settings SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_machine_settings_t_created;
CREATE TRIGGER trigger_machine_settings_t_created after insert on machine_settings BEGIN UPDATE machine_settings SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_machine_settings_t_updated;
CREATE TRIGGER trigger_machine_settings_t_updated after update on machine_settings BEGIN UPDATE machine_settings SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_machines_t_created;
CREATE TRIGGER trigger_machines_t_created after insert on machines BEGIN UPDATE machines SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_machines_t_updated;
CREATE TRIGGER trigger_machines_t_updated after update on machines BEGIN UPDATE machines SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_product_settings_t_created;
CREATE TRIGGER trigger_product_settings_t_created after insert on product_settings BEGIN UPDATE product_settings SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_product_settings_t_updated;
CREATE TRIGGER trigger_product_settings_t_updated after update on product_settings BEGIN UPDATE product_settings SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_products_t_created;
CREATE TRIGGER trigger_products_t_created after insert on products BEGIN UPDATE products SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_products_t_updated;
CREATE TRIGGER trigger_products_t_updated after update on products BEGIN UPDATE products SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_secrets_t_created;
CREATE TRIGGER trigger_secrets_t_created after insert on secrets BEGIN UPDATE secrets SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_secrets_t_updated;
CREATE TRIGGER trigger_secrets_t_updated after update on secrets BEGIN UPDATE secrets SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_test_suite_settings_t_created;
CREATE TRIGGER trigger_test_suite_settings_t_created after insert on test_suite_settings BEGIN UPDATE test_suite_settings SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_test_suite_settings_t_updated;
CREATE TRIGGER trigger_test_suite_settings_t_updated after update on test_suite_settings BEGIN UPDATE test_suite_settings SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_test_suites_t_created;
CREATE TRIGGER trigger_test_suites_t_created after insert on test_suites BEGIN UPDATE test_suites SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_test_suites_t_updated;
CREATE TRIGGER trigger_test_suites_t_updated after update on test_suites BEGIN UPDATE test_suites SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_users_t_created;
CREATE TRIGGER trigger_users_t_created after insert on users BEGIN UPDATE users SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_users_t_updated;
CREATE TRIGGER trigger_users_t_updated after update on users BEGIN UPDATE users SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_workers_t_created;
CREATE TRIGGER trigger_workers_t_created after insert on workers BEGIN UPDATE workers SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_workers_t_updated;
CREATE TRIGGER trigger_workers_t_updated after update on workers BEGIN UPDATE workers SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_api_keys_t_created;
CREATE TRIGGER trigger_api_keys_t_created after insert on api_keys BEGIN UPDATE api_keys SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_api_keys_t_updated;
CREATE TRIGGER trigger_api_keys_t_updated after update on api_keys BEGIN UPDATE api_keys SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_commands_t_created;
CREATE TRIGGER trigger_commands_t_created after insert on commands BEGIN UPDATE commands SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_commands_t_updated;
CREATE TRIGGER trigger_commands_t_updated after update on commands BEGIN UPDATE commands SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_job_templates_t_created;
CREATE TRIGGER trigger_job_templates_t_created after insert on job_templates BEGIN UPDATE job_templates SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_job_templates_t_updated;
CREATE TRIGGER trigger_job_templates_t_updated after update on job_templates BEGIN UPDATE job_templates SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_jobs_t_created;
CREATE TRIGGER trigger_jobs_t_created after insert on jobs BEGIN UPDATE jobs SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_jobs_t_updated;
CREATE TRIGGER trigger_jobs_t_updated after update on jobs BEGIN UPDATE jobs SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_jobs_assets_t_created;
CREATE TRIGGER trigger_jobs_assets_t_created after insert on jobs_assets BEGIN UPDATE jobs_assets SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_jobs_assets_t_updated;
CREATE TRIGGER trigger_jobs_assets_t_updated after update on jobs_assets BEGIN UPDATE jobs_assets SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
COMMIT;
