-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/94/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/95/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE api_keys ALTER COLUMN id TYPE bigint;

;
ALTER TABLE api_keys ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE assets ALTER COLUMN id TYPE bigint;

;
ALTER TABLE assets ALTER COLUMN last_use_job_id TYPE bigint;

;
ALTER TABLE audit_events ALTER COLUMN id TYPE bigint;

;
ALTER TABLE audit_events ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE bugs ALTER COLUMN id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN group_id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN parent_group_id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE developer_sessions ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE developer_sessions ALTER COLUMN user_id TYPE bigint;

;
ALTER TABLE gru_dependencies ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE gru_dependencies ALTER COLUMN gru_task_id TYPE bigint;

;
ALTER TABLE gru_tasks ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_dependencies ALTER COLUMN child_job_id TYPE bigint;

;
ALTER TABLE job_dependencies ALTER COLUMN parent_job_id TYPE bigint;

;
ALTER TABLE job_group_parents ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_groups ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_groups ALTER COLUMN parent_id TYPE bigint;

;
ALTER TABLE job_modules ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE job_networks ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE job_settings ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_settings ALTER COLUMN job_id TYPE bigint;

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
ALTER TABLE jobs ALTER COLUMN id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN clone_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN blocked_by_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN group_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN assigned_worker_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN scheduled_product_id TYPE bigint;

;
ALTER TABLE jobs_assets ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE jobs_assets ALTER COLUMN asset_id TYPE bigint;

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
ALTER TABLE screenshot_links ALTER COLUMN job_id TYPE bigint;

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
ALTER TABLE worker_properties ALTER COLUMN id TYPE bigint;

;
ALTER TABLE worker_properties ALTER COLUMN worker_id TYPE bigint;

;
ALTER TABLE workers ALTER COLUMN id TYPE bigint;

;
ALTER TABLE workers ALTER COLUMN job_id TYPE bigint;

;

-- Ensure sequences are converted to bigint as well as it does not seem to be the case on all setups
ALTER SEQUENCE IF EXISTS dbix_class_deploymenthandler_versions_id_seq AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS gru_tasks_id_seq                             AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS audit_events_id_seq                          AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS comments_id_seq                              AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS job_group_parents_id_seq                     AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS job_groups_id_seq                            AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS job_modules_id_seq                           AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS job_settings_id_seq                          AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS job_templates_id_seq                         AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS job_template_settings_id_seq                 AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS machine_settings_id_seq                      AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS jobs_id_seq                                  AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS machines_id_seq                              AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS needle_dirs_id_seq                           AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS product_settings_id_seq                      AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS needles_id_seq                               AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS products_id_seq                              AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS scheduled_products_id_seq                    AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS screenshots_id_seq                           AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS secrets_id_seq                               AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS test_suite_settings_id_seq                   AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS test_suites_id_seq                           AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS worker_properties_id_seq                     AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS users_id_seq                                 AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS workers_id_seq                               AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS bugs_id_seq                                  AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS api_keys_id_seq                              AS bigint NO MAXVALUE;
ALTER SEQUENCE IF EXISTS assets_id_seq                                AS bigint NO MAXVALUE;

COMMIT;

