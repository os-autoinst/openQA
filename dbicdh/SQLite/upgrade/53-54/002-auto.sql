-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/53/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/54/001-auto.yml':;

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
  TEST text NOT NULL,
  DISTRI text NOT NULL DEFAULT '',
  VERSION text NOT NULL DEFAULT '',
  FLAVOR text NOT NULL DEFAULT '',
  ARCH text NOT NULL DEFAULT '',
  BUILD text NOT NULL DEFAULT '',
  MACHINE text,
  group_id integer,
  assigned_worker_id integer,
  t_started timestamp,
  t_finished timestamp,
  logs_present boolean NOT NULL DEFAULT 1,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (assigned_worker_id) REFERENCES workers(id) ON DELETE SET NULL ON UPDATE CASCADE,
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
  TEST text NOT NULL,
  DISTRI text NOT NULL DEFAULT '',
  VERSION text NOT NULL DEFAULT '',
  FLAVOR text NOT NULL DEFAULT '',
  ARCH text NOT NULL DEFAULT '',
  BUILD text NOT NULL DEFAULT '',
  MACHINE text,
  group_id integer,
  assigned_worker_id integer,
  t_started timestamp,
  t_finished timestamp,
  logs_present boolean NOT NULL DEFAULT 1,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (assigned_worker_id) REFERENCES workers(id) ON DELETE SET NULL ON UPDATE CASCADE,
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

COMMIT;
