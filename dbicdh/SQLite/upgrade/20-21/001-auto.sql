-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/20/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/21/001-auto.yml':;

;
BEGIN;

;
CREATE TEMPORARY TABLE job_dependencies_temp_alter (
  child_job_id integer NOT NULL,
  parent_job_id integer NOT NULL,
  dependency integer NOT NULL,
  PRIMARY KEY (child_job_id, parent_job_id, dependency),
  FOREIGN KEY (child_job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (parent_job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
INSERT INTO job_dependencies_temp_alter( child_job_id, parent_job_id) SELECT child_job_id, parent_job_id FROM job_dependencies;

;
DROP TABLE job_dependencies;

;
CREATE TABLE job_dependencies (
  child_job_id integer NOT NULL,
  parent_job_id integer NOT NULL,
  dependency integer NOT NULL,
  PRIMARY KEY (child_job_id, parent_job_id, dependency),
  FOREIGN KEY (child_job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (parent_job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_dependencies_idx_child_00 ON job_dependencies (child_job_id);

;
CREATE INDEX job_dependencies_idx_parent00 ON job_dependencies (parent_job_id);

;
CREATE INDEX idx_job_dependencies_depend00 ON job_dependencies (dependency);

;
INSERT INTO job_dependencies SELECT child_job_id, parent_job_id, dependency FROM job_dependencies_temp_alter;

;
DROP TABLE job_dependencies_temp_alter;

;
DROP TABLE dependencies;

;

COMMIT;

