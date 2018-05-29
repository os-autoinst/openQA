-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/63/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/64/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP COLUMN retry_avbl;

;
ALTER TABLE needles DROP CONSTRAINT needles_fk_first_seen_module_id;

;
DROP INDEX needles_idx_first_seen_module_id;

;
ALTER TABLE needles DROP COLUMN first_seen_module_id;

;
ALTER TABLE needles ADD COLUMN last_seen timestamp;

;
ALTER TABLE needles ADD COLUMN last_matched timestamp;

;
DROP TABLE job_module_needles CASCADE;

;

COMMIT;

