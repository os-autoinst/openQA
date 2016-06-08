-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/37/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/38/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP CONSTRAINT jobs_fk_worker_id;

;
DROP INDEX jobs_idx_worker_id;

;
ALTER TABLE jobs DROP COLUMN worker_id;

;
ALTER TABLE workers ADD COLUMN job_id integer;

;
CREATE INDEX workers_idx_job_id on workers (job_id);

;
ALTER TABLE workers ADD CONSTRAINT workers_job_id UNIQUE (job_id);

;
ALTER TABLE workers ADD CONSTRAINT workers_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE DEFERRABLE;

;

COMMIT;

