-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/23/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/24/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules ADD COLUMN soft_failure integer NOT NULL DEFAULT 0;

;
ALTER TABLE job_modules ADD COLUMN milestone integer NOT NULL DEFAULT 0;

;
ALTER TABLE job_modules ADD COLUMN important integer NOT NULL DEFAULT 0;

;
ALTER TABLE job_modules ADD COLUMN fatal integer NOT NULL DEFAULT 0;

;
CREATE TEMPORARY TABLE jobs_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  slug text,
  state varchar NOT NULL DEFAULT 'scheduled',
  priority integer NOT NULL DEFAULT 50,
  result varchar NOT NULL DEFAULT 'none',
  worker_id integer NOT NULL DEFAULT 0,
  test text NOT NULL,
  clone_id integer,
  retry_avbl integer NOT NULL DEFAULT 3,
  backend_info text,
  t_started timestamp,
  t_finished timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (clone_id) REFERENCES jobs(id) ON DELETE SET NULL,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO jobs_temp_alter( id, slug, state, priority, result, worker_id, test, clone_id, retry_avbl, t_started, t_finished, t_created, t_updated) SELECT id, slug, state, priority, result, worker_id, test, clone_id, retry_avbl, t_started, t_finished, t_created, t_updated FROM jobs;

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
  clone_id integer,
  retry_avbl integer NOT NULL DEFAULT 3,
  backend_info text,
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
INSERT INTO jobs SELECT id, slug, state, priority, result, worker_id, test, clone_id, retry_avbl, backend_info, t_started, t_finished, t_created, t_updated FROM jobs_temp_alter;

;
DROP TABLE jobs_temp_alter;

;

COMMIT;

