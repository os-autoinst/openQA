-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/61/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/62/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE assets DROP CONSTRAINT assets_fk_last_use_job_id;

;
ALTER TABLE assets ADD CONSTRAINT assets_fk_last_use_job_id FOREIGN KEY (last_use_job_id)
  REFERENCES jobs (id) ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

