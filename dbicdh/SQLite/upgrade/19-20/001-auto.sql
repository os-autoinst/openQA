-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/19/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/20/001-auto.yml':;

;
BEGIN;

;
CREATE TEMPORARY TABLE job_modules_temp_alter (
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

;
INSERT INTO job_modules_temp_alter( id, job_id, name, script, category, result, t_created, t_updated) SELECT id, job_id, name, script, category, result, t_created, t_updated FROM job_modules;

;
DROP TABLE job_modules;

;
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

;
CREATE INDEX job_modules_idx_job_id02 ON job_modules (job_id);

;
CREATE INDEX idx_job_modules_result02 ON job_modules (result);

;
INSERT INTO job_modules SELECT id, job_id, name, script, category, result, t_created, t_updated FROM job_modules_temp_alter;

;
DROP TABLE job_modules_temp_alter;

;
CREATE TEMPORARY TABLE jobs_temp_alter (
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

;
INSERT INTO jobs_temp_alter( id, slug, state, priority, result, worker_id, test, test_branch, clone_id, retry_avbl, t_started, t_finished, t_created, t_updated) SELECT id, slug, state, priority, result, worker_id, test, test_branch, clone_id, retry_avbl, t_started, t_finished, t_created, t_updated FROM jobs;

;
DROP TABLE jobs;

;
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

;
CREATE INDEX jobs_idx_clone_id02 ON jobs (clone_id);

;
CREATE INDEX jobs_idx_worker_id02 ON jobs (worker_id);

;
CREATE INDEX idx_jobs_state02 ON jobs (state);

;
CREATE INDEX idx_jobs_result02 ON jobs (result);

;
CREATE UNIQUE INDEX jobs_slug02 ON jobs (slug);

;
INSERT INTO jobs SELECT id, slug, state, priority, result, worker_id, test, test_branch, clone_id, retry_avbl, t_started, t_finished, t_created, t_updated FROM jobs_temp_alter;

;
DROP TABLE jobs_temp_alter;

;
DROP TABLE job_results;

;
DROP TABLE job_states;

;

COMMIT;

