-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/33/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/34/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE needles (
  id INTEGER PRIMARY KEY NOT NULL,
  filename text NOT NULL,
  first_seen_module_id integer NOT NULL,
  last_seen_module_id integer NOT NULL,
  last_matched_module_id integer,
  FOREIGN KEY (first_seen_module_id) REFERENCES job_modules(id),
  FOREIGN KEY (last_matched_module_id) REFERENCES job_modules(id),
  FOREIGN KEY (last_seen_module_id) REFERENCES job_modules(id)
);

;
CREATE INDEX needles_idx_first_seen_module_id ON needles (first_seen_module_id);

;
CREATE INDEX needles_idx_last_matched_module_id ON needles (last_matched_module_id);

;
CREATE INDEX needles_idx_last_seen_module_id ON needles (last_seen_module_id);

;
CREATE UNIQUE INDEX needles_filename ON needles (filename);

;

COMMIT;

