-- Convert schema '/home/lukas/Code/openQA/script/../dbicdh/_source/deploy/58/001-auto.yml' to '/home/lukas/Code/openQA/script/../dbicdh/_source/deploy/59/001-auto.yml':;

;
BEGIN;

;
CREATE TEMPORARY TABLE users_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  username text NOT NULL,
  email text,
  fullname text,
  nickname text,
  is_operator integer NOT NULL DEFAULT 0,
  is_admin integer NOT NULL DEFAULT 0,
  feature_version integer NOT NULL DEFAULT 1,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO users_temp_alter( id, username, email, fullname, nickname, is_operator, is_admin, feature_version, t_created, t_updated) SELECT id, username, email, fullname, nickname, is_operator, is_admin, feature_version, t_created, t_updated FROM users;

;
DROP TABLE users;

;
CREATE TABLE users (
  id INTEGER PRIMARY KEY NOT NULL,
  username text NOT NULL,
  email text,
  fullname text,
  nickname text,
  is_operator integer NOT NULL DEFAULT 0,
  is_admin integer NOT NULL DEFAULT 0,
  feature_version integer NOT NULL DEFAULT 1,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX users_username02 ON users (username);

;
INSERT INTO users SELECT id, username, email, fullname, nickname, is_operator, is_admin, feature_version, t_created, t_updated FROM users_temp_alter;

;
DROP TABLE users_temp_alter;

;

COMMIT;

