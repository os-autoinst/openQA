-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/37/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/38/001-auto.yml':;

;
BEGIN;

ALTER TABLE workers ADD COLUMN job_id integer;

;
CREATE INDEX workers_idx_job_id ON workers (job_id);

;
CREATE UNIQUE INDEX workers_job_id ON workers (job_id);

;

COMMIT;

