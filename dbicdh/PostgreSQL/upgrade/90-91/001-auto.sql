-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/90/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/91/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users DROP CONSTRAINT users_username;

;
ALTER TABLE users ADD COLUMN provider text DEFAULT '' NOT NULL;

;
ALTER TABLE users ADD CONSTRAINT users_username_provider UNIQUE (username, provider);

;

COMMIT;

