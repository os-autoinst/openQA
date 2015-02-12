-- Convert schema '/home/openQA/script/../dbicdh/_source/deploy/22/001-auto.yml' to '/home/openQA/script/../dbicdh/_source/deploy/23/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users ADD COLUMN username text,
                  ADD UNIQUE users_username (username);

;
UPDATE TABLE users SET username = openid;

;
ALTER TABLE users DROP INDEX users_openid,
                  DROP COLUMN openid;

ALTER TABLE users CHANGE username text NOT NULL;

;

COMMIT;

