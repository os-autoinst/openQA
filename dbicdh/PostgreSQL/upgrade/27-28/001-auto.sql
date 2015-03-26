-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/28/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP CONSTRAINT jobs_fk_worker_id;

;
ALTER TABLE jobs ADD CONSTRAINT jobs_fk_worker_id FOREIGN KEY (worker_id)
  REFERENCES workers (id) ON DELETE CASCADE DEFERRABLE;

;
ALTER TABLE workers DROP COLUMN backend;

;

COMMIT;

