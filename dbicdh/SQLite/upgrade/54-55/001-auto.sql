-- Convert schema '/usr/share/openqa/script/../dbicdh/_source/deploy/54/001-auto.yml' to '/usr/share/openqa/script/../dbicdh/_source/deploy/55/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE bugs (
  id INTEGER PRIMARY KEY NOT NULL,
  bugid text NOT NULL,
  title text,
  priority text,
  assigned boolean,
  assignee text,
  open boolean,
  status text,
  resolution text,
  existing boolean NOT NULL DEFAULT 1,
  refreshed boolean NOT NULL DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX bugs_bugid ON bugs (bugid);

;

COMMIT;

