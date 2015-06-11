-- Convert schema '/root/openQA/script/../dbicdh/_source/deploy/30/001-auto.yml' to '/root/openQA/script/../dbicdh/_source/deploy/31/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_networks (
  name text NOT NULL,
  job_id integer NOT NULL,
  vlan integer NOT NULL,
  PRIMARY KEY (name, job_id),
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX job_networks_idx_job_id ON job_networks (job_id);

;

COMMIT;

