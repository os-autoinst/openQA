-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/20/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/21/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_dependencies DROP CONSTRAINT job_dependencies_pkey;

;
ALTER TABLE job_dependencies DROP CONSTRAINT job_dependencies_fk_dep_id;

;
DROP INDEX job_dependencies_idx_dep_id;

;
ALTER TABLE job_dependencies DROP COLUMN dep_id;

;
ALTER TABLE job_dependencies ADD COLUMN dependency integer NOT NULL;

;
CREATE INDEX idx_job_dependencies_dependency on job_dependencies (dependency);

;
ALTER TABLE job_dependencies ADD PRIMARY KEY (child_job_id, parent_job_id, dependency);

;
DROP TABLE dependencies CASCADE;

;

COMMIT;

