-- Convert schema '/home/sri/work/openQA/repos/openQA/script/../dbicdh/_source/deploy/80/001-auto.yml' to '/home/sri/work/openQA/repos/openQA/script/../dbicdh/_source/deploy/81/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_modules ADD CONSTRAINT job_modules_job_id_name_category_script UNIQUE (job_id, name, category, script);

;

COMMIT;

