-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/33/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/34/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_module_needles (
  needle_id integer NOT NULL,
  job_module_id integer NOT NULL,
  matched boolean NOT NULL DEFAULT 1,
  FOREIGN KEY (job_module_id) REFERENCES job_modules(id),
  FOREIGN KEY (needle_id) REFERENCES needles(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_module_needles_idx_job_module_id ON job_module_needles (job_module_id);

;
CREATE INDEX job_module_needles_idx_needle_id ON job_module_needles (needle_id);

;
CREATE UNIQUE INDEX job_module_needles_needle_id_job_module_id ON job_module_needles (needle_id, job_module_id);

;
CREATE TABLE needle_dirs (
  id INTEGER PRIMARY KEY NOT NULL,
  path text NOT NULL,
  name text NOT NULL
);

;
CREATE UNIQUE INDEX needle_dirs_path ON needle_dirs (path);

;
CREATE TABLE needles (
  id INTEGER PRIMARY KEY NOT NULL,
  dir_id integer NOT NULL,
  filename text NOT NULL,
  first_seen_module_id integer NOT NULL,
  last_seen_module_id integer NOT NULL,
  last_matched_module_id integer,
  FOREIGN KEY (dir_id) REFERENCES needle_dirs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (first_seen_module_id) REFERENCES job_modules(id),
  FOREIGN KEY (last_matched_module_id) REFERENCES job_modules(id),
  FOREIGN KEY (last_seen_module_id) REFERENCES job_modules(id)
);

;
CREATE INDEX needles_idx_dir_id ON needles (dir_id);

;
CREATE INDEX needles_idx_first_seen_module_id ON needles (first_seen_module_id);

;
CREATE INDEX needles_idx_last_matched_module_id ON needles (last_matched_module_id);

;
CREATE INDEX needles_idx_last_seen_module_id ON needles (last_seen_module_id);

;
CREATE UNIQUE INDEX needles_dir_id_filename ON needles (dir_id, filename);

;

COMMIT;

