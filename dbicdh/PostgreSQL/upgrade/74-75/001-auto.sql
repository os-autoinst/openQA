-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/74/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/75/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE workers DROP CONSTRAINT workers_fk_job_id;

;
ALTER TABLE workers ADD CONSTRAINT workers_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE SET NULL DEFERRABLE;

;

COMMIT;

