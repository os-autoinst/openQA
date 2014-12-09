-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/16/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/17/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_modules (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer NOT NULL,
  name text NOT NULL,
  script text NOT NULL,
  category text NOT NULL,
  result_id integer NOT NULL DEFAULT 0,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (result_id) REFERENCES job_results(id)
);

;
CREATE INDEX job_modules_idx_job_id ON job_modules (job_id);

;
CREATE INDEX job_modules_idx_result_id ON job_modules (result_id);

;

COMMIT;

