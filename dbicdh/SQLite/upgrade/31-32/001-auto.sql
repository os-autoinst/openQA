-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/31/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/32/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE comments (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer,
  group_id integer,
  text text NOT NULL,
  user_id integer NOT NULL,
  hidden boolean NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

;
CREATE INDEX comments_idx_group_id ON comments (group_id);

;
CREATE INDEX comments_idx_job_id ON comments (job_id);

;
CREATE INDEX comments_idx_user_id ON comments (user_id);

;

COMMIT;

