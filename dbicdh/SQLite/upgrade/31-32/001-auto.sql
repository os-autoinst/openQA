-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/31/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/32/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_comments (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer NOT NULL,
  text text NOT NULL,
  user_id integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id),
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_comments_idx_user_id ON job_comments (user_id);

;
CREATE INDEX job_comments_idx_job_id ON job_comments (job_id);

;

COMMIT;

