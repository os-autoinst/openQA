-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/39/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/40/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_module_needles DROP CONSTRAINT job_module_needles_fk_job_module_id;

;
ALTER TABLE job_module_needles ADD CONSTRAINT job_module_needles_fk_job_module_id FOREIGN KEY (job_module_id)
  REFERENCES job_modules (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE job_modules DROP CONSTRAINT job_modules_fk_job_id;

;
ALTER TABLE job_modules ADD CONSTRAINT job_modules_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

