-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/15/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/16/001-auto.yml':;

BEGIN;

;
CREATE TABLE worker_properties (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL, 
  value text NOT NULL,
  worker_id integer NOT NULL, 
  t_created timestamp, 
  t_updated timestamp, 
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX worker_properties_idx_worker_id ON worker_properties (worker_id);

;

COMMIT;

;
-- No differences found;

