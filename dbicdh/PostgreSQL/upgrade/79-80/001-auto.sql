-- Convert schema '/home/kalikiana/dev/openQA/repos/openQA/script/../dbicdh/_source/deploy/79/001-auto.yml' to '/home/kalikiana/dev/openQA/repos/openQA/script/../dbicdh/_source/deploy/80/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_templates DROP CONSTRAINT job_templates_product_id_machine_id_test_suite_id;

;
ALTER TABLE job_templates ADD COLUMN name text;

;
ALTER TABLE job_templates ADD CONSTRAINT job_templates_product_id_machine_id_name_test_suite_id UNIQUE (product_id, machine_id, name, test_suite_id);

;

COMMIT;

