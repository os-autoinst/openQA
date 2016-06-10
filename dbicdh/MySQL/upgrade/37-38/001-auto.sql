-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/37/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/38/001-auto.yml':;

;
BEGIN;

ALTER TABLE workers ADD COLUMN job_id integer NULL,
                    ADD INDEX workers_idx_job_id (job_id),
                    ADD UNIQUE workers_job_id (job_id),
                    ADD CONSTRAINT workers_fk_job_id FOREIGN KEY (job_id) REFERENCES jobs (id) ON DELETE CASCADE;

;

COMMIT;

