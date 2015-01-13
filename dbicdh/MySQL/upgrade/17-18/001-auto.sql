-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/17/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/18/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE api_keys CHANGE COLUMN t_created t_created timestamp NOT NULL,
                     CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE assets CHANGE COLUMN t_created t_created timestamp NOT NULL,
                   CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE commands CHANGE COLUMN t_created t_created timestamp NOT NULL,
                     CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE job_modules CHANGE COLUMN t_created t_created timestamp NOT NULL,
                        CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE job_settings DROP INDEX job_settings_kv_index,
                         CHANGE COLUMN t_created t_created timestamp NOT NULL,
                         CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE job_templates CHANGE COLUMN t_created t_created timestamp NOT NULL,
                          CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE jobs CHANGE COLUMN t_created t_created timestamp NOT NULL,
                 CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE jobs_assets CHANGE COLUMN t_created t_created timestamp NOT NULL,
                        CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE machine_settings CHANGE COLUMN t_created t_created timestamp NOT NULL,
                             CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE machines CHANGE COLUMN t_created t_created timestamp NOT NULL,
                     CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE product_settings CHANGE COLUMN t_created t_created timestamp NOT NULL,
                             CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE products CHANGE COLUMN t_created t_created timestamp NOT NULL,
                     CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE secrets CHANGE COLUMN t_created t_created timestamp NOT NULL,
                    CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE test_suite_settings CHANGE COLUMN t_created t_created timestamp NOT NULL,
                                CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE test_suites CHANGE COLUMN t_created t_created timestamp NOT NULL,
                        CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE users CHANGE COLUMN t_created t_created timestamp NOT NULL,
                  CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;
ALTER TABLE worker_properties DROP FOREIGN KEY worker_properties_fk_worker_id;

;
ALTER TABLE worker_properties DROP INDEX worker_properties_kv_index,
                              CHANGE COLUMN t_created t_created timestamp NOT NULL,
                              CHANGE COLUMN t_updated t_updated timestamp NOT NULL,
                              ADD CONSTRAINT worker_properties_fk_worker_id FOREIGN KEY (worker_id) REFERENCES workers (id) ON DELETE CASCADE ON UPDATE CASCADE;

;
ALTER TABLE workers CHANGE COLUMN t_created t_created timestamp NOT NULL,
                    CHANGE COLUMN t_updated t_updated timestamp NOT NULL;

;

COMMIT;

