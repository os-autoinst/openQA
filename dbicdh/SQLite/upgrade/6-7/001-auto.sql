-- Convert schema '/usr/share/openqa/script/../dbicdh/_source/deploy/6/001-auto.yml' to '/usr/share/openqa/script/../dbicdh/_source/deploy/7/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE jobs ADD COLUMN retry_avbl integer NOT NULL DEFAULT 3;

;

COMMIT;

