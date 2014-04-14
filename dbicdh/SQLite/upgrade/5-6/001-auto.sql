-- Convert schema '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/5/001-auto.yml' to '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/6/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE assets (
  id INTEGER PRIMARY KEY NOT NULL,
  type text NOT NULL,
  name text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);

;
CREATE UNIQUE INDEX assets_type_name ON assets (type, name);

;
CREATE TABLE jobs_assets (
  job_id integer NOT NULL,
  asset_id integer NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (asset_id) REFERENCES assets(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX jobs_assets_idx_asset_id ON jobs_assets (asset_id);

;
CREATE INDEX jobs_assets_idx_job_id ON jobs_assets (job_id);

;
CREATE UNIQUE INDEX constraint_name06 ON jobs_assets (job_id, asset_id);

;

COMMIT;

