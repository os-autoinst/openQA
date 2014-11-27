-- Convert schema '/usr/share/openqa/script/../dbicdh/_source/deploy/14/001-auto.yml' to '/usr/share/openqa/script/../dbicdh/_source/deploy/15/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE dependencies (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL
);

;
CREATE TABLE job_dependencies (
  child_job_id integer NOT NULL,
  parent_job_id integer NOT NULL,
  dep_id integer NOT NULL,
  PRIMARY KEY (child_job_id, parent_job_id, dep_id),
  FOREIGN KEY (child_job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (dep_id) REFERENCES dependencies(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (parent_job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_dependencies_idx_child_job_id ON job_dependencies (child_job_id);

;
CREATE INDEX job_dependencies_idx_dep_id ON job_dependencies (dep_id);

;
CREATE INDEX job_dependencies_idx_parent_job_id ON job_dependencies (parent_job_id);

;

COMMIT;

