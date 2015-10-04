-- Convert schema '/home/adamw/openQA/script/../dbicdh/_source/deploy/32/001-auto.yml' to '/home/adamw/openQA/script/../dbicdh/_source/deploy/33/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE gru_dependencies (
  job_id integer NOT NULL,
  gru_task_id integer NOT NULL,
  PRIMARY KEY (job_id, gru_task_id)
);
CREATE INDEX gru_dependencies_idx_gru_task_id on gru_dependencies (gru_task_id);
CREATE INDEX gru_dependencies_idx_job_id on gru_dependencies (job_id);

;
ALTER TABLE gru_dependencies ADD CONSTRAINT gru_dependencies_fk_gru_task_id FOREIGN KEY (gru_task_id)
  REFERENCES gru_tasks (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE gru_dependencies ADD CONSTRAINT gru_dependencies_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

