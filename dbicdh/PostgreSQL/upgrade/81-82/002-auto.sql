-- Convert schema '/home/kalikiana/dev/openQA/repos/openQA/script/../dbicdh/_source/deploy/81/001-auto.yml' to '/home/kalikiana/dev/openQA/repos/openQA/script/../dbicdh/_source/deploy/82/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates DROP CONSTRAINT job_templates_product_id_machine_id_name_test_suite_id;

;
ALTER TABLE job_templates ALTER COLUMN name SET NOT NULL;

;
ALTER TABLE job_templates ALTER COLUMN name SET DEFAULT '';

;
ALTER TABLE job_templates ADD CONSTRAINT scenario UNIQUE (product_id, machine_id, name, test_suite_id);

;

COMMIT;

