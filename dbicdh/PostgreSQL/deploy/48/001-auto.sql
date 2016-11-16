-- 
-- Created by SQL::Translator::Producer::PostgreSQL
-- Created on Thu Nov 17 07:49:45 2016
-- 
;
--
-- Table: assets
--
CREATE TABLE assets (
  id serial NOT NULL,
  type text NOT NULL,
  name text NOT NULL,
  size bigint,
  checksum text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT assets_type_name UNIQUE (type, name)
);

;
--
-- Table: gru_tasks
--
CREATE TABLE gru_tasks (
  id serial NOT NULL,
  taskname text NOT NULL,
  args text NOT NULL,
  run_at timestamp NOT NULL,
  priority integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id)
);
CREATE INDEX gru_tasks_run_at_reversed on gru_tasks (run_at DESC);

;
--
-- Table: job_group_parents
--
CREATE TABLE job_group_parents (
  id serial NOT NULL,
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
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT job_group_parents_name UNIQUE (name)
);

;
--
-- Table: job_modules
--
CREATE TABLE job_modules (
  id serial NOT NULL,
  job_id integer NOT NULL,
  name text NOT NULL,
  script text NOT NULL,
  category text NOT NULL,
  milestone integer DEFAULT 0 NOT NULL,
  important integer DEFAULT 0 NOT NULL,
  fatal integer DEFAULT 0 NOT NULL,
  result character varying DEFAULT 'none' NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id)
);
CREATE INDEX job_modules_idx_job_id on job_modules (job_id);
CREATE INDEX idx_job_modules_result on job_modules (result);

;
--
-- Table: job_settings
--
CREATE TABLE job_settings (
  id serial NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  job_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id)
);
CREATE INDEX job_settings_idx_job_id on job_settings (job_id);
CREATE INDEX idx_value_settings on job_settings (key, value);
CREATE INDEX idx_job_id_value_settings on job_settings (job_id, key, value);

;
--
-- Table: machine_settings
--
CREATE TABLE machine_settings (
  id serial NOT NULL,
  machine_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT machine_settings_machine_id_key UNIQUE (machine_id, key)
);
CREATE INDEX machine_settings_idx_machine_id on machine_settings (machine_id);

;
--
-- Table: machines
--
CREATE TABLE machines (
  id serial NOT NULL,
  name text NOT NULL,
  backend text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT machines_name UNIQUE (name)
);

;
--
-- Table: needle_dirs
--
CREATE TABLE needle_dirs (
  id serial NOT NULL,
  path text NOT NULL,
  name text NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT needle_dirs_path UNIQUE (path)
);

;
--
-- Table: product_settings
--
CREATE TABLE product_settings (
  id serial NOT NULL,
  product_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT product_settings_product_id_key UNIQUE (product_id, key)
);
CREATE INDEX product_settings_idx_product_id on product_settings (product_id);

;
--
-- Table: products
--
CREATE TABLE products (
  id serial NOT NULL,
  name text NOT NULL,
  distri text NOT NULL,
  version text DEFAULT '' NOT NULL,
  arch text NOT NULL,
  flavor text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT products_distri_version_arch_flavor UNIQUE (distri, version, arch, flavor)
);

;
--
-- Table: screenshots
--
CREATE TABLE screenshots (
  id serial NOT NULL,
  filename text NOT NULL,
  t_created timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT screenshots_filename UNIQUE (filename)
);

;
--
-- Table: secrets
--
CREATE TABLE secrets (
  id serial NOT NULL,
  secret text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT secrets_secret UNIQUE (secret)
);

;
--
-- Table: test_suite_settings
--
CREATE TABLE test_suite_settings (
  id serial NOT NULL,
  test_suite_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT test_suite_settings_test_suite_id_key UNIQUE (test_suite_id, key)
);
CREATE INDEX test_suite_settings_idx_test_suite_id on test_suite_settings (test_suite_id);

;
--
-- Table: test_suites
--
CREATE TABLE test_suites (
  id serial NOT NULL,
  name text NOT NULL,
  variables text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT test_suites_name UNIQUE (name)
);

;
--
-- Table: users
--
CREATE TABLE users (
  id serial NOT NULL,
  username text NOT NULL,
  email text,
  fullname text,
  nickname text,
  is_operator integer DEFAULT 0 NOT NULL,
  is_admin integer DEFAULT 0 NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT users_username UNIQUE (username)
);

;
--
-- Table: worker_properties
--
CREATE TABLE worker_properties (
  id serial NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  worker_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id)
);
CREATE INDEX worker_properties_idx_worker_id on worker_properties (worker_id);

;
--
-- Table: api_keys
--
CREATE TABLE api_keys (
  id serial NOT NULL,
  key text NOT NULL,
  secret text NOT NULL,
  user_id integer NOT NULL,
  t_expiration timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT api_keys_key UNIQUE (key)
);
CREATE INDEX api_keys_idx_user_id on api_keys (user_id);

;
--
-- Table: audit_events
--
CREATE TABLE audit_events (
  id serial NOT NULL,
  user_id integer,
  connection_id text,
  event text NOT NULL,
  event_data text,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id)
);
CREATE INDEX audit_events_idx_user_id on audit_events (user_id);

;
--
-- Table: comments
--
CREATE TABLE comments (
  id serial NOT NULL,
  job_id integer,
  group_id integer,
  text text NOT NULL,
  user_id integer NOT NULL,
  flags integer DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id)
);
CREATE INDEX comments_idx_group_id on comments (group_id);
CREATE INDEX comments_idx_job_id on comments (job_id);
CREATE INDEX comments_idx_user_id on comments (user_id);

;
--
-- Table: job_groups
--
CREATE TABLE job_groups (
  id serial NOT NULL,
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
  PRIMARY KEY (id),
  CONSTRAINT job_groups_name UNIQUE (name)
);
CREATE INDEX job_groups_idx_parent_id on job_groups (parent_id);

;
--
-- Table: jobs
--
CREATE TABLE jobs (
  id serial NOT NULL,
  slug text,
  result_dir text,
  state character varying DEFAULT 'scheduled' NOT NULL,
  priority integer DEFAULT 50 NOT NULL,
  result character varying DEFAULT 'none' NOT NULL,
  clone_id integer,
  retry_avbl integer DEFAULT 3 NOT NULL,
  backend character varying,
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
  PRIMARY KEY (id),
  CONSTRAINT jobs_slug UNIQUE (slug)
);
CREATE INDEX jobs_idx_clone_id on jobs (clone_id);
CREATE INDEX jobs_idx_group_id on jobs (group_id);
CREATE INDEX idx_jobs_state on jobs (state);
CREATE INDEX idx_jobs_result on jobs (result);
CREATE INDEX idx_jobs_build_group on jobs (BUILD, group_id);
CREATE INDEX idx_jobs_scenario on jobs (VERSION, DISTRI, FLAVOR, TEST, MACHINE, ARCH);

;
--
-- Table: needles
--
CREATE TABLE needles (
  id serial NOT NULL,
  dir_id integer NOT NULL,
  filename text NOT NULL,
  first_seen_module_id integer NOT NULL,
  last_seen_module_id integer NOT NULL,
  last_matched_module_id integer,
  file_present boolean DEFAULT '1' NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT needles_dir_id_filename UNIQUE (dir_id, filename)
);
CREATE INDEX needles_idx_dir_id on needles (dir_id);
CREATE INDEX needles_idx_first_seen_module_id on needles (first_seen_module_id);
CREATE INDEX needles_idx_last_matched_module_id on needles (last_matched_module_id);
CREATE INDEX needles_idx_last_seen_module_id on needles (last_seen_module_id);

;
--
-- Table: job_dependencies
--
CREATE TABLE job_dependencies (
  child_job_id integer NOT NULL,
  parent_job_id integer NOT NULL,
  dependency integer NOT NULL,
  PRIMARY KEY (child_job_id, parent_job_id, dependency)
);
CREATE INDEX job_dependencies_idx_child_job_id on job_dependencies (child_job_id);
CREATE INDEX job_dependencies_idx_parent_job_id on job_dependencies (parent_job_id);
CREATE INDEX idx_job_dependencies_dependency on job_dependencies (dependency);

;
--
-- Table: job_locks
--
CREATE TABLE job_locks (
  name text NOT NULL,
  owner integer NOT NULL,
  locked_by text,
  count integer DEFAULT 1 NOT NULL,
  PRIMARY KEY (name, owner)
);
CREATE INDEX job_locks_idx_owner on job_locks (owner);

;
--
-- Table: job_module_needles
--
CREATE TABLE job_module_needles (
  needle_id integer NOT NULL,
  job_module_id integer NOT NULL,
  matched boolean DEFAULT '1' NOT NULL,
  CONSTRAINT job_module_needles_needle_id_job_module_id UNIQUE (needle_id, job_module_id)
);
CREATE INDEX job_module_needles_idx_job_module_id on job_module_needles (job_module_id);
CREATE INDEX job_module_needles_idx_needle_id on job_module_needles (needle_id);

;
--
-- Table: job_networks
--
CREATE TABLE job_networks (
  name text NOT NULL,
  job_id integer NOT NULL,
  vlan integer NOT NULL,
  PRIMARY KEY (name, job_id)
);
CREATE INDEX job_networks_idx_job_id on job_networks (job_id);

;
--
-- Table: workers
--
CREATE TABLE workers (
  id serial NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  job_id integer,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT workers_host_instance UNIQUE (host, instance),
  CONSTRAINT workers_job_id UNIQUE (job_id)
);
CREATE INDEX workers_idx_job_id on workers (job_id);

;
--
-- Table: gru_dependencies
--
CREATE TABLE gru_dependencies (
  job_id integer NOT NULL,
  gru_task_id integer NOT NULL,
  PRIMARY KEY (job_id, gru_task_id)
);
CREATE INDEX gru_dependencies_idx_gru_task_id on gru_dependencies (gru_task_id);
CREATE INDEX gru_dependencies_idx_job_id on gru_dependencies (job_id);

;
--
-- Table: jobs_assets
--
CREATE TABLE jobs_assets (
  job_id integer NOT NULL,
  asset_id integer NOT NULL,
  created_by boolean DEFAULT '0' NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  CONSTRAINT jobs_assets_job_id_asset_id UNIQUE (job_id, asset_id)
);
CREATE INDEX jobs_assets_idx_asset_id on jobs_assets (asset_id);
CREATE INDEX jobs_assets_idx_job_id on jobs_assets (job_id);

;
--
-- Table: screenshot_links
--
CREATE TABLE screenshot_links (
  screenshot_id integer NOT NULL,
  job_id integer NOT NULL
);
CREATE INDEX screenshot_links_idx_job_id on screenshot_links (job_id);
CREATE INDEX screenshot_links_idx_screenshot_id on screenshot_links (screenshot_id);

;
--
-- Table: job_templates
--
CREATE TABLE job_templates (
  id serial NOT NULL,
  product_id integer NOT NULL,
  machine_id integer NOT NULL,
  test_suite_id integer NOT NULL,
  prio integer NOT NULL,
  group_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT job_templates_product_id_machine_id_test_suite_id UNIQUE (product_id, machine_id, test_suite_id)
);
CREATE INDEX job_templates_idx_group_id on job_templates (group_id);
CREATE INDEX job_templates_idx_machine_id on job_templates (machine_id);
CREATE INDEX job_templates_idx_product_id on job_templates (product_id);
CREATE INDEX job_templates_idx_test_suite_id on job_templates (test_suite_id);

;
--
-- Foreign Key Definitions
--

;
ALTER TABLE job_modules ADD CONSTRAINT job_modules_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_settings ADD CONSTRAINT job_settings_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE machine_settings ADD CONSTRAINT machine_settings_fk_machine_id FOREIGN KEY (machine_id)
  REFERENCES machines (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE product_settings ADD CONSTRAINT product_settings_fk_product_id FOREIGN KEY (product_id)
  REFERENCES products (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE test_suite_settings ADD CONSTRAINT test_suite_settings_fk_test_suite_id FOREIGN KEY (test_suite_id)
  REFERENCES test_suites (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE worker_properties ADD CONSTRAINT worker_properties_fk_worker_id FOREIGN KEY (worker_id)
  REFERENCES workers (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE api_keys ADD CONSTRAINT api_keys_fk_user_id FOREIGN KEY (user_id)
  REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE audit_events ADD CONSTRAINT audit_events_fk_user_id FOREIGN KEY (user_id)
  REFERENCES users (id) DEFERRABLE;

;
ALTER TABLE comments ADD CONSTRAINT comments_fk_group_id FOREIGN KEY (group_id)
  REFERENCES job_groups (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE comments ADD CONSTRAINT comments_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE comments ADD CONSTRAINT comments_fk_user_id FOREIGN KEY (user_id)
  REFERENCES users (id) DEFERRABLE;

;
ALTER TABLE job_groups ADD CONSTRAINT job_groups_fk_parent_id FOREIGN KEY (parent_id)
  REFERENCES job_group_parents (id) ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE jobs ADD CONSTRAINT jobs_fk_clone_id FOREIGN KEY (clone_id)
  REFERENCES jobs (id) ON DELETE SET NULL DEFERRABLE;

;
ALTER TABLE jobs ADD CONSTRAINT jobs_fk_group_id FOREIGN KEY (group_id)
  REFERENCES job_groups (id) ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE needles ADD CONSTRAINT needles_fk_dir_id FOREIGN KEY (dir_id)
  REFERENCES needle_dirs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE needles ADD CONSTRAINT needles_fk_first_seen_module_id FOREIGN KEY (first_seen_module_id)
  REFERENCES job_modules (id) DEFERRABLE;

;
ALTER TABLE needles ADD CONSTRAINT needles_fk_last_matched_module_id FOREIGN KEY (last_matched_module_id)
  REFERENCES job_modules (id) DEFERRABLE;

;
ALTER TABLE needles ADD CONSTRAINT needles_fk_last_seen_module_id FOREIGN KEY (last_seen_module_id)
  REFERENCES job_modules (id) DEFERRABLE;

;
ALTER TABLE job_dependencies ADD CONSTRAINT job_dependencies_fk_child_job_id FOREIGN KEY (child_job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_dependencies ADD CONSTRAINT job_dependencies_fk_parent_job_id FOREIGN KEY (parent_job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_locks ADD CONSTRAINT job_locks_fk_owner FOREIGN KEY (owner)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_module_needles ADD CONSTRAINT job_module_needles_fk_job_module_id FOREIGN KEY (job_module_id)
  REFERENCES job_modules (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_module_needles ADD CONSTRAINT job_module_needles_fk_needle_id FOREIGN KEY (needle_id)
  REFERENCES needles (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_networks ADD CONSTRAINT job_networks_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE workers ADD CONSTRAINT workers_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE DEFERRABLE;

;
ALTER TABLE gru_dependencies ADD CONSTRAINT gru_dependencies_fk_gru_task_id FOREIGN KEY (gru_task_id)
  REFERENCES gru_tasks (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE gru_dependencies ADD CONSTRAINT gru_dependencies_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE jobs_assets ADD CONSTRAINT jobs_assets_fk_asset_id FOREIGN KEY (asset_id)
  REFERENCES assets (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE jobs_assets ADD CONSTRAINT jobs_assets_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE screenshot_links ADD CONSTRAINT screenshot_links_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE screenshot_links ADD CONSTRAINT screenshot_links_fk_screenshot_id FOREIGN KEY (screenshot_id)
  REFERENCES screenshots (id) DEFERRABLE;

;
ALTER TABLE job_templates ADD CONSTRAINT job_templates_fk_group_id FOREIGN KEY (group_id)
  REFERENCES job_groups (id) DEFERRABLE;

;
ALTER TABLE job_templates ADD CONSTRAINT job_templates_fk_machine_id FOREIGN KEY (machine_id)
  REFERENCES machines (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_templates ADD CONSTRAINT job_templates_fk_product_id FOREIGN KEY (product_id)
  REFERENCES products (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_templates ADD CONSTRAINT job_templates_fk_test_suite_id FOREIGN KEY (test_suite_id)
  REFERENCES test_suites (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
