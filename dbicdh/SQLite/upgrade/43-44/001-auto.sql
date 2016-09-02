-- Convert schema '/home/openQA/openQA/script/../dbicdh/_source/deploy/43/001-auto.yml' to '/home/openQA/openQA/script/../dbicdh/_source/deploy/44/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE assets ADD COLUMN checksum text;

;
CREATE TEMPORARY TABLE comments_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer,
  group_id integer,
  text text NOT NULL,
  user_id integer NOT NULL,
  flags integer DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

;
INSERT INTO comments_temp_alter( id, job_id, group_id, text, user_id, t_created, t_updated) SELECT id, job_id, group_id, text, user_id, t_created, t_updated FROM comments;

;
DROP TABLE comments;

;
CREATE TABLE comments (
  id INTEGER PRIMARY KEY NOT NULL,
  job_id integer,
  group_id integer,
  text text NOT NULL,
  user_id integer NOT NULL,
  flags integer DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

;
CREATE INDEX comments_idx_group_id02 ON comments (group_id);

;
CREATE INDEX comments_idx_job_id02 ON comments (job_id);

;
CREATE INDEX comments_idx_user_id02 ON comments (user_id);

;
INSERT INTO comments SELECT id, job_id, group_id, text, user_id, flags, t_created, t_updated FROM comments_temp_alter;

;
DROP TABLE comments_temp_alter;

;
CREATE TEMPORARY TABLE job_locks_temp_alter (
  name text NOT NULL,
  owner integer NOT NULL,
  locked_by text,
  count integer NOT NULL DEFAULT 1,
  PRIMARY KEY (name, owner),
  FOREIGN KEY (owner) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO job_locks_temp_alter( name, owner, locked_by) SELECT name, owner, locked_by FROM job_locks;

;
DROP TABLE job_locks;

;
CREATE TABLE job_locks (
  name text NOT NULL,
  owner integer NOT NULL,
  locked_by text,
  count integer NOT NULL DEFAULT 1,
  PRIMARY KEY (name, owner),
  FOREIGN KEY (owner) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_locks_idx_owner02 ON job_locks (owner);

;
INSERT INTO job_locks SELECT name, owner, locked_by, count FROM job_locks_temp_alter;

;
DROP TABLE job_locks_temp_alter;

;

COMMIT;

