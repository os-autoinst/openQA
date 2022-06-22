-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/96/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/97/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE api_keys ALTER COLUMN id TYPE bigint;

;
ALTER TABLE api_keys ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE audit_events ALTER COLUMN id TYPE bigint;

;
ALTER TABLE audit_events ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE bugs ALTER COLUMN id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN group_id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN parent_group_id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE developer_sessions ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE gru_dependencies ALTER COLUMN gru_task_id TYPE bigint;

;
ALTER TABLE gru_tasks ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_group_parents ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_groups ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_groups ALTER COLUMN parent_id TYPE bigint;

;
ALTER TABLE job_template_settings ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_template_settings ALTER COLUMN job_template_id TYPE bigint;

;
ALTER TABLE job_templates ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_templates ALTER COLUMN product_id TYPE bigint;

;
ALTER TABLE job_templates ALTER COLUMN machine_id TYPE bigint;

;
ALTER TABLE job_templates ALTER COLUMN test_suite_id TYPE bigint;

;
ALTER TABLE job_templates ALTER COLUMN group_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN group_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN scheduled_product_id TYPE bigint;

;
ALTER TABLE machine_settings ALTER COLUMN id TYPE bigint;

;
ALTER TABLE machine_settings ALTER COLUMN machine_id TYPE bigint;

;
ALTER TABLE machines ALTER COLUMN id TYPE bigint;

;
ALTER TABLE needle_dirs ALTER COLUMN id TYPE bigint;

;
ALTER TABLE needles ALTER COLUMN id TYPE bigint;

;
ALTER TABLE needles ALTER COLUMN dir_id TYPE bigint;

;
ALTER TABLE product_settings ALTER COLUMN id TYPE bigint;

;
ALTER TABLE product_settings ALTER COLUMN product_id TYPE bigint;

;
ALTER TABLE products ALTER COLUMN id TYPE bigint;

;
ALTER TABLE scheduled_products ALTER COLUMN id TYPE bigint;

;
ALTER TABLE scheduled_products ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE scheduled_products ALTER COLUMN gru_task_id TYPE bigint;

;
ALTER TABLE scheduled_products ALTER COLUMN minion_job_id TYPE bigint;

;
ALTER TABLE screenshot_links ALTER COLUMN screenshot_id TYPE bigint;

;
ALTER TABLE screenshots ALTER COLUMN id TYPE bigint;

;
ALTER TABLE secrets ALTER COLUMN id TYPE bigint;

;
ALTER TABLE test_suite_settings ALTER COLUMN id TYPE bigint;

;
ALTER TABLE test_suite_settings ALTER COLUMN test_suite_id TYPE bigint;

;
ALTER TABLE test_suites ALTER COLUMN id TYPE bigint;

;
ALTER TABLE users ALTER COLUMN id TYPE bigint;

;

COMMIT;

