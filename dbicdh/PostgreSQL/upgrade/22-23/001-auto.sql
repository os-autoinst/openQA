-- Convert schema '/home/openQA/script/../dbicdh/_source/deploy/22/001-auto.yml' to '/home/openQA/script/../dbicdh/_source/deploy/23/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users ADD COLUMN username text;

;
ALTER TABLE users ADD CONSTRAINT users_username UNIQUE (username);

;
UPDATE users SET username = openid;

;
ALTER TABLE users DROP CONSTRAINT users_openid;

;
ALTER TABLE users DROP COLUMN openid;

;
ALTER TABLE users ALTER COLUMN username SET NOT NULL;

;

COMMIT;

