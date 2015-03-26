-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/27/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/28/001-auto.yml':;

;
BEGIN;

;
DROP INDEX jobs_fk_worker_id;

;

;
CREATE TEMPORARY TABLE workers_temp_alter (
  id INTEGER PRIMARY KEY NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
INSERT INTO workers_temp_alter( id, host, instance, t_created, t_updated) SELECT id, host, instance, t_created, t_updated FROM workers;

;
DROP TABLE workers;

;
CREATE TABLE workers (
  id INTEGER PRIMARY KEY NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL
);

;
CREATE UNIQUE INDEX workers_host_instance02 ON workers (host, instance);

;
INSERT INTO workers SELECT id, host, instance, t_created, t_updated FROM workers_temp_alter;

;
DROP TABLE workers_temp_alter;

;

COMMIT;

