-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/17/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/18/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE api_keys ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE api_keys ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE assets ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE assets ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE commands ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE commands ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE job_modules ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE job_modules ALTER COLUMN t_updated SET NOT NULL;

;
DROP INDEX job_settings_kv_index;

;
ALTER TABLE job_settings ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE job_settings ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE job_templates ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE job_templates ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE jobs ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE jobs ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE jobs_assets ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE jobs_assets ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE machine_settings ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE machine_settings ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE machines ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE machines ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE product_settings ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE product_settings ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE products ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE products ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE secrets ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE secrets ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE test_suite_settings ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE test_suite_settings ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE test_suites ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE test_suites ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE users ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE users ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE worker_properties DROP CONSTRAINT worker_properties_fk_worker_id;

;
DROP INDEX worker_properties_kv_index;

;
ALTER TABLE worker_properties ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE worker_properties ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE worker_properties ADD CONSTRAINT worker_properties_fk_worker_id FOREIGN KEY (worker_id)
  REFERENCES workers (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE workers ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE workers ALTER COLUMN t_updated SET NOT NULL;

;

COMMIT;

