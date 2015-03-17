-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/28/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates ADD COLUMN prio integer;

;
ALTER TABLE job_templates ADD COLUMN group_id integer;

;
CREATE INDEX job_templates_idx_group_id on job_templates (group_id);

;
ALTER TABLE job_templates ADD CONSTRAINT job_templates_fk_group_id FOREIGN KEY (group_id)
  REFERENCES job_groups (id) DEFERRABLE;

;

COMMIT;

