-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/77/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/78/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_template_settings (
  id serial NOT NULL,
  job_template_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT job_template_settings_job_template_id_key UNIQUE (job_template_id, key)
);
CREATE INDEX job_template_settings_idx_job_template_id on job_template_settings (job_template_id);

;
ALTER TABLE job_template_settings ADD CONSTRAINT job_template_settings_fk_job_template_id FOREIGN KEY (job_template_id)
  REFERENCES job_templates (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

