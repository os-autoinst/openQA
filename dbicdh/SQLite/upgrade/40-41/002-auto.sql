-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/40/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/41/001-auto.yml':;

;
BEGIN;

;
CREATE TEMPORARY TABLE job_modules_temp_alter (
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

;
INSERT INTO job_modules_temp_alter( id, job_id, name, script, category, milestone, important, fatal, result, t_created, t_updated) SELECT id, job_id, name, script, category, milestone, important, fatal, result, t_created, t_updated FROM job_modules;

;
DROP TABLE job_modules;

;
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

;
CREATE INDEX job_modules_idx_job_id02 ON job_modules (job_id);

;
CREATE INDEX idx_job_modules_result02 ON job_modules (result);

;
INSERT INTO job_modules SELECT id, job_id, name, script, category, milestone, important, fatal, result, t_created, t_updated FROM job_modules_temp_alter;

;
DROP TABLE job_modules_temp_alter;

;

COMMIT;

