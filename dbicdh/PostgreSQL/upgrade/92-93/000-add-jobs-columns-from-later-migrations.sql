-- Add columns to the jobs table that really come from later schema versions, but need to be present early for the perl scripts in this 92-93 migration to work:;

BEGIN;

;
ALTER TABLE jobs ADD COLUMN videos_present boolean DEFAULT '1' NOT NULL;
ALTER TABLE jobs ADD COLUMN results_present boolean DEFAULT '1' NOT NULL;

;

COMMIT;
