-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/39/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/40/001-auto.yml':;

;
BEGIN;

;
CREATE INDEX idx_jobs_scenario ON jobs (VERSION, DISTRI, FLAVOR, TEST, MACHINE, ARCH);

;

COMMIT;

