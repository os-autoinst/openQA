-- Convert schema '/home/adamw/openQA/script/../dbicdh/_source/deploy/32/001-auto.yml' to '/home/adamw/openQA/script/../dbicdh/_source/deploy/33/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE gru_dependencies (
  job_id integer NOT NULL,
  gru_task_id integer NOT NULL,
  INDEX gru_dependencies_idx_gru_task_id (gru_task_id),
  INDEX gru_dependencies_idx_job_id (job_id),
  PRIMARY KEY (job_id, gru_task_id),
  CONSTRAINT gru_dependencies_fk_gru_task_id FOREIGN KEY (gru_task_id) REFERENCES gru_tasks (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT gru_dependencies_fk_job_id FOREIGN KEY (job_id) REFERENCES jobs (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;
ALTER TABLE gru_tasks ENGINE=InnoDB;

;

COMMIT;

