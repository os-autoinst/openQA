-- Convert schema '/home/openQA/script/../dbicdh/_source/deploy/24/001-auto.yml' to '/home/openQA/script/../dbicdh/_source/deploy/25/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_locks (
  name text NOT NULL,
  owner integer NOT NULL,
  locked_by integer,
  PRIMARY KEY (name, owner),
  FOREIGN KEY (locked_by) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (owner) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_locks_idx_locked_by ON job_locks (locked_by);

;
CREATE INDEX job_locks_idx_owner ON job_locks (owner);

;

COMMIT;

