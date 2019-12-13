-- Convert schema '/home/tina/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/83/001-auto.yml' to '/home/tina/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/84/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates DROP CONSTRAINT job_templates_fk_group_id;

;
ALTER TABLE job_templates ADD COLUMN description text DEFAULT '' NOT NULL;

;
ALTER TABLE job_templates ADD CONSTRAINT job_templates_fk_group_id FOREIGN KEY (group_id)
  REFERENCES job_groups (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

