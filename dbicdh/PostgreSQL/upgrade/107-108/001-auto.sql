-- Convert schema '/home/okurz/local/os-autoinst/oqa2/script/../dbicdh/_source/deploy/107/001-auto.yml' to '/home/okurz/local/os-autoinst/oqa2/script/../dbicdh/_source/deploy/108/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE job_impacts (
  job_id integer NOT NULL,
  seconds integer NOT NULL,
  vcpus real NOT NULL,
  ram_gb real NOT NULL,
  power_w real NOT NULL,
  energy_kwh double precision NOT NULL,
  carbon_g double precision NOT NULL,
  cost_energy double precision NOT NULL,
  cost_hardware double precision NOT NULL,
  cost_human double precision,
  cost_total double precision NOT NULL,
  currency text NOT NULL,
  model_version integer NOT NULL,
  factors jsonb NOT NULL,
  t_created timestamp with time zone NOT NULL,
  PRIMARY KEY (job_id)
);

;
ALTER TABLE job_impacts ADD CONSTRAINT job_impacts_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE DEFERRABLE;

;

COMMIT;

