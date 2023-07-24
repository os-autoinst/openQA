-- Convert schema '/home/adamw/local/openQA/script/../dbicdh/_source/deploy/100/001-auto.yml' to '/home/adamw/local/openQA/script/../dbicdh/_source/deploy/101/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS videos_present boolean DEFAULT '1' NOT NULL;

;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS results_present boolean DEFAULT '1' NOT NULL;

;

COMMIT;

