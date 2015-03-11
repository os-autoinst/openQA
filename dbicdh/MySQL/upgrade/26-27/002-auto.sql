-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/28/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates ADD COLUMN prio integer NULL,
                          ADD COLUMN group_id integer NULL,
                          ADD INDEX job_templates_idx_group_id (group_id),
                          ADD CONSTRAINT job_templates_fk_group_id FOREIGN KEY (group_id) REFERENCES job_groups (id);

;

COMMIT;

