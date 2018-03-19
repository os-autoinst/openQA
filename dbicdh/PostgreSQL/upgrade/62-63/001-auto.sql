-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/62/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/63/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE needles ADD COLUMN tags text[];

;
ALTER TABLE needles ADD COLUMN t_created timestamp;
UPDATE needles SET t_created = (TIMESTAMP '-infinity') WHERE t_created IS NULL;
ALTER TABLE needles ALTER COLUMN t_created SET NOT NULL;

;
ALTER TABLE needles ADD COLUMN t_updated timestamp;
UPDATE needles SET t_updated = (TIMESTAMP '-infinity') WHERE t_updated IS NULL;
ALTER TABLE needles ALTER COLUMN t_updated SET NOT NULL;

;
ALTER TABLE needles ALTER COLUMN first_seen_module_id DROP NOT NULL;

;
ALTER TABLE needles ALTER COLUMN last_seen_module_id DROP NOT NULL;

;

COMMIT;

