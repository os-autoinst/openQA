-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/47/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/48/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE screenshots (
  id INTEGER PRIMARY KEY NOT NULL,
  filename text NOT NULL,
  t_created timestamp NOT NULL
);

;
CREATE UNIQUE INDEX screenshots_filename ON screenshots (filename);

;

COMMIT;

