-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/20/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/21/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_dependencies DROP PRIMARY KEY,
                             DROP FOREIGN KEY job_dependencies_fk_dep_id,
                             DROP INDEX job_dependencies_idx_dep_id,
                             DROP COLUMN dep_id,
                             ADD COLUMN dependency integer NOT NULL,
                             ADD INDEX idx_job_dependencies_dependency (dependency),
                             ADD PRIMARY KEY (child_job_id, parent_job_id, dependency);

;
DROP TABLE dependencies;

;

COMMIT;

