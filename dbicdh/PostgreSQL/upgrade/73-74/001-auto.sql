-- Convert schema '/home/clemix/sandbox/openQA/script/../dbicdh/_source/deploy/73/001-auto.yml' to '/home/clemix/sandbox/openQA/script/../dbicdh/_source/deploy/74/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN externally_skipped_module_count integer DEFAULT 0 NOT NULL;

;

COMMIT;

