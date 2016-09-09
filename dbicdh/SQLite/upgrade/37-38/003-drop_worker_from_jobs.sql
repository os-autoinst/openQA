-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/37/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/38/001-auto.yml':;

;
BEGIN;

;
DROP INDEX idx_job_value_settings;

;
CREATE INDEX idx_job_id_value_settings ON job_settings (job_id, key, value);

;
CREATE TEMPORARY TABLE jobs_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  slug text,
  result_dir text,
  state varchar NOT NULL DEFAULT 'scheduled',
  priority integer NOT NULL DEFAULT 50,
  result varchar NOT NULL DEFAULT 'none',
  test text NOT NULL,
  clone_id integer,
  retry_avbl integer NOT NULL DEFAULT 3,
  backend varchar,
  backend_info text,
  group_id integer,
  t_started timestamp,
  t_finished timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (clone_id) REFERENCES jobs(id) ON DELETE SET NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE SET NULL ON UPDATE CASCADE
);

;
INSERT INTO jobs_temp_alter( id, slug, result_dir, state, priority, result, test, clone_id, retry_avbl, backend, backend_info, group_id, t_started, t_finished, t_created, t_updated) SELECT id, slug, result_dir, state, priority, result, test, clone_id, retry_avbl, backend, backend_info, group_id, t_started, t_finished, t_created, t_updated FROM jobs;

;
DROP TABLE jobs;

;
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY NOT NULL,
  slug text,
  result_dir text,
  state varchar NOT NULL DEFAULT 'scheduled',
  priority integer NOT NULL DEFAULT 50,
  result varchar NOT NULL DEFAULT 'none',
  test text NOT NULL,
  clone_id integer,
  retry_avbl integer NOT NULL DEFAULT 3,
  backend varchar,
  backend_info text,
  group_id integer,
  t_started timestamp,
  t_finished timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (clone_id) REFERENCES jobs(id) ON DELETE SET NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE SET NULL ON UPDATE CASCADE
);

;
CREATE INDEX jobs_idx_clone_id02 ON jobs (clone_id);

;
CREATE INDEX jobs_idx_group_id02 ON jobs (group_id);

;
CREATE INDEX idx_jobs_state02 ON jobs (state);

;
CREATE INDEX idx_jobs_result02 ON jobs (result);

;
CREATE UNIQUE INDEX jobs_slug02 ON jobs (slug);

;
INSERT INTO jobs SELECT id, slug, result_dir, state, priority, result, test, clone_id, retry_avbl, backend, backend_info, group_id, t_started, t_finished, t_created, t_updated FROM jobs_temp_alter;

;
DROP TABLE jobs_temp_alter;

;

COMMIT;

