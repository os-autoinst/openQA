-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/63/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/64/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs DROP COLUMN retry_avbl;

;
ALTER TABLE needles DROP CONSTRAINT needles_fk_first_seen_module_id;

;
ALTER TABLE needles DROP CONSTRAINT needles_fk_last_matched_module_id;

;
ALTER TABLE needles DROP CONSTRAINT needles_fk_last_seen_module_id;

;
DROP INDEX needles_idx_first_seen_module_id;

;
ALTER TABLE needles DROP COLUMN first_seen_module_id;

;
ALTER TABLE needles ADD COLUMN last_seen_time timestamp;

;
ALTER TABLE needles ADD COLUMN last_matched_time timestamp;

;
ALTER TABLE needles ADD CONSTRAINT needles_fk_last_matched_module_id FOREIGN KEY (last_matched_module_id)
  REFERENCES job_modules (id) ON DELETE SET NULL DEFERRABLE;

;
ALTER TABLE needles ADD CONSTRAINT needles_fk_last_seen_module_id FOREIGN KEY (last_seen_module_id)
  REFERENCES job_modules (id) ON DELETE SET NULL DEFERRABLE;

;
DROP TABLE job_module_needles CASCADE;

;

COMMIT;

